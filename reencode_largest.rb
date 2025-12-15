#!/usr/bin/env ruby

require 'find'
require 'fileutils'
require 'rbconfig'
require 'json'
require 'logger'

# --- Configuration ---
# List of video file extensions to search for. Case-insensitive.
# Can be overridden via VIDEO_EXTENSIONS environment variable (comma-separated)
VIDEO_EXTENSIONS = ENV.fetch('VIDEO_EXTENSIONS', '.mp4,.mkv,.avi,.wmv,.mov,.flv,.m4v').split(',').map(&:strip)
# The command-line argument that triggers replacement of the original file.
REPLACE_FLAG = '--replace'
# The command-line argument to explicitly NOT replace the original file.
NO_REPLACE_FLAG = '--no-replace'
# The command-line argument that forces a full rescan of the filesystem.
RESCAN_FLAG = '--rescan'
# The command-line argument for dry-run mode (no actual encoding).
DRYRUN_FLAG = '--dryrun'
# Minimum file size reduction percentage required for replacement (safety check)
MIN_SIZE_REDUCTION_PERCENT = ENV.fetch('MIN_SIZE_REDUCTION', '10').to_f
# The directory to search in. '.' means the current directory.
# Can be overridden via TARGET_DIRECTORY environment variable
TARGET_DIRECTORY = ENV.fetch('TARGET_DIRECTORY', '.')
# H.265 encoding quality. Lower values are higher quality.
# Can be overridden via CRF_VALUE environment variable
CRF_VALUE = ENV.fetch('CRF_VALUE', '20')
# Encoding preset. 'medium' is a good balance of speed and compression.
# Can be overridden via PRESET environment variable
PRESET = ENV.fetch('PRESET', 'medium')
# The name of the cache file.
# Can be overridden via CACHE_FILE environment variable
CACHE_FILE = ENV.fetch('CACHE_FILE', 'filesize_cache.json')
# Enable GPU acceleration (NVIDIA NVENC). Set to 'true' to use GPU.
# Can be overridden via USE_GPU environment variable
USE_GPU = ENV.fetch('USE_GPU', 'false').downcase == 'true'

# --- Logger Setup ---
# Log file path
LOG_FILE = ENV.fetch('LOG_FILE', '/videos/h265_encoder.log')

# Create a multi-output logger (logs to both STDOUT and file)
log_file_writer = File.open(LOG_FILE, 'a')
log_file_writer.sync = true  # Ensure immediate writes

class MultiIO
  def initialize(*targets)
    @targets = targets
  end

  def write(*args)
    @targets.each { |t| t.write(*args) }
  end

  def close
    @targets.each(&:close)
  end
end

$logger = Logger.new(MultiIO.new(STDOUT, log_file_writer))
$logger.level = Logger::INFO
$logger.formatter = proc do |severity, datetime, progname, msg|
  "[#{datetime.strftime('%Y-%m-%d %H:%M:%S')}] #{severity}: #{msg}\n"
end

# --- Helper Functions ---

# Checks if a command exists on the system's PATH.
def command_exists?(command)
  system("which #{command} > /dev/null 2>&1")
end

# Loads the file size cache from a JSON file.
# Migrates old format (path => size) to new format (path => {size, codec})
def load_cache(file)
  if File.exist?(file)
    cache = JSON.parse(File.read(file))
    # Migrate old cache format to new format if needed
    cache.each do |path, value|
      if value.is_a?(Numeric)
        # Old format: just a size number
        cache[path] = { 'size' => value, 'codec' => nil }
      end
    end
    cache
  else
    {}
  end
rescue JSON::ParserError
  $logger.warn "Cache file is corrupt. Starting fresh."
  {}
end

# Saves the file size cache to a JSON file.
def save_cache(file, data)
  File.write(file, JSON.pretty_generate(data))
end

# Finds the largest video file, using a cache if available.
# Skips files already encoded with h.265/hevc.
def find_largest_video(cache, force_rescan)
  if !force_rescan && !cache.empty?
    $logger.info "Using cache to find largest file. Use --rescan to find new files."
    # Find the largest file from the cache that still exists and is not h.265
    sorted_files = cache.sort_by { |_, info| -(info['size'] || 0) }
    
    sorted_files.each do |path, info|
      size = info['size']
      codec = info['codec']
      
      unless File.exist?(path)
        $logger.info "Cached file not found, removing: #{path}"
        cache.delete(path) # Clean up non-existent files from cache
        next
      end
      
      # Check codec, fetch if not in cache
      if codec.nil?
        codec = get_video_codec(path)
        info['codec'] = codec
      end
      
      # Skip h.265/hevc encoded files
      if codec == 'hevc' || codec == 'h265'
        $logger.info "Skipping h.265 file: #{path} (#{(size / 1_048_576.0).round(2)} MB, codec: #{codec})"
        next
      end
      
      $logger.info "Found largest non-h.265 file in cache: #{path} (#{(size / 1_048_576.0).round(2)} MB, codec: #{codec || 'unknown'})"
      return { path: path, size: size, codec: codec }
    end
    
    $logger.info "Cache contained no valid non-h.265 files to encode."
    return nil
  end

  # Perform a full scan if cache is empty, not used, or contains no valid files.
  $logger.info "Performing full filesystem scan..."
  largest_file_path = nil
  max_size = -1
  scanned_files = {}
  spinner = ['|', '/', '-', '\\']
  count = 0

  Find.find(TARGET_DIRECTORY) do |path|
    count += 1
    print "\rScanning... #{spinner[count / 100 % 4]}" if count % 100 == 0

    next if File.directory?(path)

    if VIDEO_EXTENSIONS.include?(File.extname(path).downcase)
      begin
        size = File.size(path)
        codec = get_video_codec(path)
        
        scanned_files[path] = { 'size' => size, 'codec' => codec }
        
        # Skip h.265/hevc encoded files
        if codec == 'hevc' || codec == 'h265'
          next
        end
        
        if size > max_size
          max_size = size
          largest_file_path = path
        end
      rescue Errno::ENOENT
        # File might have been deleted during the scan.
      end
    end
  end

  print "\rScanning... Done.              \n"

  # Update the main cache with the results of the new scan.
  cache.clear.merge!(scanned_files)

  if largest_file_path
    return { path: largest_file_path, size: max_size, codec: scanned_files[largest_file_path]['codec'] }
  else
    return nil
  end
end

# Uses ffprobe to get the framerate of a video file.
def get_framerate(file_path)
  return nil unless command_exists?('ffprobe')
  command = "ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=noprint_wrappers=1:nokey=1 \"#{file_path}\""
  framerate_str = `#{command}`.strip
  return framerate_str.empty? ? nil : framerate_str
end

# Uses ffprobe to get the video codec of a file.
def get_video_codec(file_path)
  return nil unless command_exists?('ffprobe')
  command = "ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 \"#{file_path}\""
  codec = `#{command}`.strip
  return codec.empty? ? nil : codec
end

# Opens the given path in the system's default file explorer.
def open_in_explorer(path)
  absolute_path = File.expand_path(path)
  case RbConfig::CONFIG['host_os']
  when /mswin|msys|mingw|cygwin|bccwin|wince|emc/
    system("explorer \"#{absolute_path.gsub('/', '\\')}\"")
  when /darwin|mac os/
    system("open \"#{absolute_path}\"")
  when /linux/
    system("xdg-open \"#{absolute_path}\"")
  else
    $logger.warn "Unsupported OS for opening file explorer. Please navigate to '#{absolute_path}' manually."
  end
end

# --- Main Script Logic ---

# 1. Check for dependencies
unless command_exists?('ffmpeg')
  $logger.error "ffmpeg is required. Please install it and ensure it's in your PATH."
  exit 1
end

# 2. Parse arguments
# Check if the first argument is a number (count of videos to process)
# Priority: ARGV[0] > NUM_FILES env var > default of 1
count_to_process = ENV.fetch('NUM_FILES', '1').to_i
first_arg = ARGV[0]
if first_arg && first_arg.match?(/^\d+$/)
  count_to_process = first_arg.to_i
end
count_to_process = 1 if count_to_process < 1 # Ensure at least 1

# Replace original is now the DEFAULT behavior
# Use --no-replace flag to keep original file
replace_original = !ARGV.include?(NO_REPLACE_FLAG)
force_rescan = ARGV.include?(RESCAN_FLAG)
dryrun = ARGV.include?(DRYRUN_FLAG)

$logger.info ""
$logger.info "╔═══════════════════════════════════════════════════════════════════╗"
$logger.info "║           H.265/HEVC Video Re-Encoder - Starting Run             ║"
$logger.info "╚═══════════════════════════════════════════════════════════════════╝"
$logger.info ""

if dryrun
  $logger.info "⚠️  DRY RUN MODE - No actual encoding will be performed"
end
$logger.info "📊 Configuration:"
$logger.info "   - Videos to process: #{count_to_process}"
$logger.info "   - Replace originals: #{replace_original ? 'YES' : 'NO'}"
$logger.info "   - CRF Value: #{CRF_VALUE}"
$logger.info "   - Preset: #{PRESET}"
$logger.info "   - Min size reduction: #{MIN_SIZE_REDUCTION_PERCENT}%"
$logger.info ""

# 3. Load cache and process videos
file_cache = load_cache(CACHE_FILE)
processed_count = 0

count_to_process.times do |iteration|
  $logger.info ""
  $logger.info "╔═══════════════════════════════════════════════════════════════════╗"
  $logger.info "║  📹 Processing Video #{iteration + 1} of #{count_to_process}".ljust(68) + "║"
  $logger.info "╚═══════════════════════════════════════════════════════════════════╝"
  $logger.info ""
  
  # Find the largest video file
  $logger.info "🔍 Step 1: Finding largest non-H.265 video file..."
  video_info = find_largest_video(file_cache, force_rescan)

  if video_info.nil? || video_info[:path].nil?
    $logger.info "✅ No more video files found to encode."
    break
  end

  largest_video = video_info[:path]
  original_size = video_info[:size]
  
  $logger.info "   ✓ Selected: #{File.basename(largest_video)}"
  $logger.info "   ✓ Size: #{(original_size / 1_048_576.0).round(2)} MB"
  $logger.info "   ✓ Codec: #{video_info[:codec] || 'unknown'}"
  $logger.info ""

  # 4. Determine encoding parameters
  $logger.info "⚙️  Step 2: Analyzing video parameters..."
  gop_duration_seconds = 2
  min_gop_duration_seconds = 1
  keyint = 120 # Default keyint (approx. 2 seconds at 60 fps)
  min_keyint = 60
  framerate_str = get_framerate(largest_video)

  if framerate_str
    begin
      framerate = Float(eval(framerate_str))
      keyint = [(framerate * gop_duration_seconds).round, 1].max
      min_keyint = [(framerate * min_gop_duration_seconds).round, 1].max
      min_keyint = [min_keyint, keyint].min
      $logger.info "   ✓ Framerate: #{framerate.round(2)} fps"
      $logger.info "   ✓ Keyframe interval: #{keyint} (min: #{min_keyint})"
    rescue StandardError => e
      $logger.warn "   ⚠️  Could not parse framerate '#{framerate_str}'. Using defaults."
      $logger.warn "   Error: #{e.message}"
    end
  else
    $logger.info "   ℹ️  Could not determine framerate. Using defaults (keyint: #{keyint}, min-keyint: #{min_keyint})."
  end
  $logger.info ""

  # 5. Construct and run the ffmpeg command
  dirname = File.dirname(largest_video)
  basename = File.basename(largest_video, '.*')
  output_path = File.join(dirname, "#{basename}_h265.mp4")
  temp_output_path = "#{output_path}.tmp"

  at_exit { File.delete(temp_output_path) if File.exist?(temp_output_path) }

  if USE_GPU
    # GPU-accelerated encoding with NVIDIA NVENC
    # Map CPU presets to NVENC presets (p1-p7, where p7 is slowest/best quality)
    nvenc_preset_map = {
      'ultrafast' => 'p1', 'superfast' => 'p2', 'veryfast' => 'p3',
      'faster' => 'p4', 'fast' => 'p4', 'medium' => 'p5',
      'slow' => 'p6', 'slower' => 'p7', 'veryslow' => 'p7'
    }
    nvenc_preset = nvenc_preset_map[PRESET] || 'p5'
    
    $logger.info "Using GPU acceleration (NVIDIA NVENC) with preset #{nvenc_preset}"
    
    command = [
      'ffmpeg',
      '-hwaccel', 'cuda',
      '-hwaccel_output_format', 'cuda',
      '-i', "\"#{largest_video}\"",
      '-c:v', 'hevc_nvenc',
      '-preset', nvenc_preset,
      '-cq', CRF_VALUE,
      '-profile:v', 'main',
      '-vf', 'yadif_cuda',
      '-g', keyint.to_s,
      '-keyint_min', min_keyint.to_s,
    #  '-ss', '01:27:58',
    #  '-t', '00:01:00',
      '-c:a', 'copy',
      '-movflags', '+faststart',
      '-f', 'mp4',
      '-y',
      "\"#{temp_output_path}\""
    ].join(' ')
  else
    # CPU encoding with libx265
    $logger.info "Using CPU encoding (libx265) with preset #{PRESET}"
    
    x265_params = "scenecut=0:keyint=#{keyint}:min-keyint=#{min_keyint}"
    command = [
      'ffmpeg',
      '-i', "\"#{largest_video}\"",
      '-c:v', 'libx265',
      '-crf', CRF_VALUE,
      '-preset', PRESET,
      '-tune', 'fastdecode',
      '-profile:v', 'main',
      '-vf', 'yadif',
    #  '-ss', '01:27:58',
    #  '-t', '00:01:00',
      '-c:a', 'copy',
      '-x265-params', x265_params,
      '-movflags', '+faststart',
      '-f', 'mp4',
      '-y',
      "\"#{temp_output_path}\""
    ].join(' ')
  end

  $logger.info "🎬 Step 3: Starting H.265 encoding..."
  $logger.info "   Target CRF: #{CRF_VALUE}, Preset: #{PRESET}"
  encoding_start_time = Time.now
  
  if dryrun
    $logger.info ""
    $logger.info "   [DRY RUN] Would execute: #{command}"
    $logger.info ""
    $logger.info "   [DRY RUN] Simulating successful encoding..."
    success = true
  else
    $logger.info "   This may take a long time depending on video size and settings."
    $logger.info ""
    $logger.info "   Command: #{command}"
    $logger.info ""
    $logger.info "   ⏳ Encoding in progress..."
    $logger.info ""
    success = system(command)
    $logger.info ""
  end
  
  encoding_duration = Time.now - encoding_start_time

  # 6. Handle the result
  if success
    $logger.info "✅ Step 4: Encoding completed successfully!"
    $logger.info "   ⏱️  Duration: #{(encoding_duration / 60).round(1)} minutes"
    
    # Safety checks before replacing
    if !dryrun && File.exist?(temp_output_path)
      new_size = File.size(temp_output_path)
      size_reduction = ((original_size - new_size).to_f / original_size * 100).round(2)
      
      $logger.info ""
      $logger.info "📊 Step 5: File size analysis..."
      $logger.info "   Original size:  #{(original_size / 1_048_576.0).round(2)} MB"
      $logger.info "   Encoded size:   #{(new_size / 1_048_576.0).round(2)} MB"
      $logger.info "   Size reduction: #{size_reduction}%"
      $logger.info ""
      
      # Safety check: Ensure file size reduction is significant
      if size_reduction < MIN_SIZE_REDUCTION_PERCENT
        $logger.warn "⚠️  WARNING: Size reduction (#{size_reduction}%) is less than minimum threshold (#{MIN_SIZE_REDUCTION_PERCENT}%)"
        $logger.warn "   This file may not benefit from H.265 encoding."
        
        if replace_original
          $logger.warn "   🛡️  SAFETY: Skipping replacement to preserve original file."
          $logger.warn "   Creating new file instead: #{File.basename(output_path)}"
          # Force non-replacement behavior for safety
          File.rename(temp_output_path, output_path)
          file_cache[output_path] = { 'size' => new_size, 'codec' => 'hevc' }
          file_cache.delete(largest_video)
          $logger.info "   ✓ New file saved, original preserved"
        else
          # Already in non-replace mode, just save normally
          File.rename(temp_output_path, output_path)
          file_cache[output_path] = { 'size' => new_size, 'codec' => 'hevc' }
          file_cache.delete(largest_video)
          $logger.info "   ✓ New file saved: #{File.basename(output_path)}"
        end
      else
        # Size reduction is good, proceed with intended behavior
        $logger.info "✅ Size reduction meets threshold (#{MIN_SIZE_REDUCTION_PERCENT}%). Proceeding..."
        $logger.info ""
        
        if replace_original
          $logger.info "🔄 Step 6: Replacing original file..."
          original_path = largest_video.dup
          
          # Extra safety: backup the original temporarily
          backup_path = "#{original_path}.backup_#{Time.now.to_i}"
          File.rename(original_path, backup_path)
          
          begin
            File.rename(temp_output_path, original_path)
            file_cache[original_path] = { 'size' => new_size, 'codec' => 'hevc' }
            
            # If successful, remove backup
            File.delete(backup_path)
            $logger.info "   ✓ Original file replaced successfully"
            $logger.info "   ✓ Saved #{(original_size - new_size) / 1_048_576.0} MB (#{size_reduction}% reduction)"
          rescue => e
            # If anything goes wrong, restore backup
            $logger.error "   ❌ Error during replacement: #{e.message}"
            $logger.info "   🔄 Restoring original file from backup..."
            File.rename(backup_path, original_path) if File.exist?(backup_path)
            File.delete(temp_output_path) if File.exist?(temp_output_path)
            $logger.info "   ✓ Original file restored"
            next
          end
        else
          $logger.info "💾 Step 6: Saving new encoded file..."
          File.rename(temp_output_path, output_path)
          file_cache[output_path] = { 'size' => new_size, 'codec' => 'hevc' }
          file_cache.delete(largest_video)
          $logger.info "   ✓ New file saved: #{File.basename(output_path)}"
          $logger.info "   ✓ Original preserved: #{File.basename(largest_video)}"
          open_in_explorer(dirname) if iteration == 0 # Only open explorer for first video
        end
      end
    elsif dryrun
      # Dry run mode - simulate the process
      simulated_new_size = (original_size * 0.6).to_i  # Simulate 40% reduction
      simulated_reduction = 40.0
      
      $logger.info ""
      $logger.info "[DRY RUN] Step 5: Simulated file size analysis..."
      $logger.info "   [DRY RUN] Original size:  #{(original_size / 1_048_576.0).round(2)} MB"
      $logger.info "   [DRY RUN] Estimated size: #{(simulated_new_size / 1_048_576.0).round(2)} MB"
      $logger.info "   [DRY RUN] Estimated reduction: #{simulated_reduction}%"
      $logger.info ""
      
      if replace_original
        $logger.info "   [DRY RUN] Would replace original file: #{File.basename(largest_video)}"
        $logger.info "   [DRY RUN] Safety checks would be performed before replacement"
      else
        $logger.info "   [DRY RUN] Would create new file: #{File.basename(output_path)}"
        $logger.info "   [DRY RUN] Would preserve original: #{File.basename(largest_video)}"
      end
    else
      $logger.error "❌ Error: Temporary output file not found!"
      next
    end
    
    processed_count += 1
    $logger.info ""
    $logger.info "✅ Video #{iteration + 1} processing complete!"
    $logger.info ""
    
    unless dryrun
      save_cache(CACHE_FILE, file_cache)
    end
  else
    $logger.error ""
    $logger.error "❌ Encoding failed for: #{File.basename(largest_video)}"
    $logger.error "   Please check the ffmpeg output above for errors."
    $logger.error ""
    save_cache(CACHE_FILE, file_cache) # Save cache even on failure
    exit 1
  end
  
  # After first iteration, don't force rescan anymore
  force_rescan = false
end

unless dryrun
  save_cache(CACHE_FILE, file_cache)
end

$logger.info ""
$logger.info "╔═══════════════════════════════════════════════════════════════════╗"
if dryrun
  $logger.info "║                    🏁 DRY RUN COMPLETE                            ║"
  $logger.info "╠═══════════════════════════════════════════════════════════════════╣"
  $logger.info "║  Videos analyzed: #{processed_count.to_s.rjust(3)}".ljust(68) + "║"
  $logger.info "║  No files were modified                                           ║"
  $logger.info "║  No cache was updated                                             ║"
else
  $logger.info "║                    🎉 ENCODING COMPLETE                           ║"
  $logger.info "╠═══════════════════════════════════════════════════════════════════╣"
  $logger.info "║  Videos processed: #{processed_count.to_s.rjust(3)}".ljust(68) + "║"
  $logger.info "║  Cache updated                                                    ║"
  $logger.info "║  Log saved to: #{File.basename(LOG_FILE)}".ljust(68) + "║"
end
$logger.info "╚═══════════════════════════════════════════════════════════════════╝"
$logger.info ""
