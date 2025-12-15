#!/bin/bash

# H.265 Re-encoder Test Suite
# Generates test videos and validates encoder behavior

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
BASE_TEST_DIR="./test-suite-runs"
IMAGE_NAME="h265-reencoder:test"
PASS_COUNT=0
FAIL_COUNT=0

# Helper functions
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
log_test() { echo -e "\n${YELLOW}═══════════════════════════════════════════════════════════${NC}"; echo -e "${YELLOW}TEST: $1${NC}"; echo -e "${YELLOW}═══════════════════════════════════════════════════════════${NC}"; }

# Check prerequisites
check_prereqs() {
    log_info "Checking prerequisites..."
    
    if ! command -v docker &> /dev/null; then
        log_fail "Docker is not installed"
        exit 1
    fi
    
    if ! command -v ffmpeg &> /dev/null; then
        log_fail "ffmpeg is not installed"
        exit 1
    fi
    
    log_pass "Prerequisites met"
}

# Generate a poorly-optimized test video using ffmpeg
# Creates an uncompressed-ish H.264 video that will compress well to H.265
generate_test_video() {
    local output_file="$1"
    local duration="${2:-3}"  # Default 3 seconds
    
    log_info "Generating test video: $output_file (${duration}s)"
    
    # Generate a colorful test pattern video with high bitrate H.264
    # Using testsrc2 for complex patterns, high CRF for inefficiency
    ffmpeg -y -f lavfi -i "testsrc2=duration=${duration}:size=1280x720:rate=30" \
        -f lavfi -i "sine=frequency=440:duration=${duration}" \
        -c:v libx264 -preset ultrafast -crf 10 -pix_fmt yuv420p \
        -c:a aac -b:a 192k \
        -movflags +faststart \
        "$output_file" 2>/dev/null
    
    if [[ -f "$output_file" ]]; then
        local size=$(du -h "$output_file" | cut -f1)
        log_info "Created: $output_file ($size)"
    else
        log_fail "Failed to create $output_file"
        return 1
    fi
}

# Create isolated test directory for each test
create_test_dir() {
    local test_name="$1"
    local test_dir="$BASE_TEST_DIR/$test_name"
    rm -rf "$test_dir"
    mkdir -p "$test_dir"
    echo "$test_dir"
}

# Setup test environment
setup() {
    log_info "Setting up test environment..."
    
    # Clean up any previous test directory
    rm -rf "$BASE_TEST_DIR"
    mkdir -p "$BASE_TEST_DIR"
    
    # Build the Docker image
    log_info "Building Docker image..."
    if docker build -t "$IMAGE_NAME" . > /dev/null 2>&1; then
        log_pass "Docker image built successfully"
    else
        log_fail "Docker image build failed"
        docker build -t "$IMAGE_NAME" .  # Show error
        exit 1
    fi
}

# Cleanup test environment
cleanup() {
    log_info "Cleaning up test environment..."
    rm -rf "$BASE_TEST_DIR"
}

# ============================================================================
# TEST 1: Replace Mode (CPU)
# Default behavior - should replace original file when size reduction is good
# ============================================================================
test_replace_mode() {
    log_test "Replace Mode (CPU) - Default Behavior"
    
    # Setup isolated directory
    local test_dir=$(create_test_dir "replace")
    local test_file="$test_dir/video.mp4"
    generate_test_video "$test_file" 3
    
    local original_size=$(stat -c%s "$test_file")
    log_info "Original file size: $original_size bytes"
    
    # Run encoder (default is replace mode)
    log_info "Running encoder..."
    docker run --rm \
        -v "$(pwd)/$test_dir:/videos" \
        "$IMAGE_NAME" 1
    
    # Verify: original should be replaced (same name, different content/size)
    if [[ -f "$test_file" ]]; then
        local new_size=$(stat -c%s "$test_file")
        log_info "New file size: $new_size bytes"
        
        # Check if file was re-encoded (should be smaller or have hevc codec)
        local codec=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$test_file" 2>/dev/null)
        
        if [[ "$codec" == "hevc" ]]; then
            log_pass "File was replaced with H.265 encoded version"
            
            # Verify no _h265 file was created
            if [[ ! -f "${test_file%.mp4}_h265.mp4" ]]; then
                log_pass "No duplicate _h265 file created (correct for replace mode)"
            else
                log_fail "Unexpected _h265 file created in replace mode"
            fi
        else
            log_fail "File codec is '$codec', expected 'hevc'"
        fi
    else
        log_fail "Original file missing after encode"
    fi
}

# ============================================================================
# TEST 2: No-Replace Mode (CPU)
# Should keep original and create new _h265.mp4 file
# ============================================================================
test_no_replace_mode() {
    log_test "No-Replace Mode (CPU) - Keep Original"
    
    # Setup isolated directory
    local test_dir=$(create_test_dir "no_replace")
    local test_file="$test_dir/video.mp4"
    local h265_file="$test_dir/video_h265.mp4"
    generate_test_video "$test_file" 3
    
    local original_size=$(stat -c%s "$test_file")
    local original_hash=$(md5sum "$test_file" | cut -d' ' -f1)
    log_info "Original file size: $original_size bytes, hash: $original_hash"
    
    # Run encoder with --no-replace
    log_info "Running encoder with --no-replace..."
    docker run --rm \
        -v "$(pwd)/$test_dir:/videos" \
        "$IMAGE_NAME" 1 --no-replace
    
    # Verify: original should be unchanged
    if [[ -f "$test_file" ]]; then
        local new_hash=$(md5sum "$test_file" | cut -d' ' -f1)
        if [[ "$original_hash" == "$new_hash" ]]; then
            log_pass "Original file unchanged"
        else
            log_fail "Original file was modified (hash mismatch)"
        fi
    else
        log_fail "Original file missing"
    fi
    
    # Verify: _h265 file should exist
    if [[ -f "$h265_file" ]]; then
        local codec=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$h265_file" 2>/dev/null)
        if [[ "$codec" == "hevc" ]]; then
            log_pass "New _h265.mp4 file created with H.265 codec"
        else
            log_fail "_h265 file codec is '$codec', expected 'hevc'"
        fi
    else
        log_fail "Expected _h265.mp4 file was not created"
    fi
}

# ============================================================================
# TEST 3: GPU/Hardware Encoding
# Tests NVENC encoding (will be skipped if no GPU available)
# ============================================================================
test_gpu_encoding() {
    log_test "GPU/Hardware Encoding (NVENC)"
    
    # Check if NVIDIA runtime is available
    if ! docker run --rm --gpus all nvidia/cuda:11.0-base nvidia-smi &> /dev/null; then
        log_info "NVIDIA GPU not available, skipping GPU test"
        echo -e "${YELLOW}[SKIP]${NC} GPU test skipped (no NVIDIA GPU/driver)"
        return 0
    fi
    
    # Setup isolated directory
    local test_dir=$(create_test_dir "gpu")
    local test_file="$test_dir/video.mp4"
    generate_test_video "$test_file" 3
    
    local original_size=$(stat -c%s "$test_file")
    log_info "Original file size: $original_size bytes"
    
    # Run encoder with GPU
    log_info "Running encoder with GPU..."
    docker run --rm \
        --gpus all \
        -e USE_GPU=true \
        -v "$(pwd)/$test_dir:/videos" \
        "$IMAGE_NAME" 1
    
    # Verify encoding worked
    if [[ -f "$test_file" ]]; then
        local codec=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$test_file" 2>/dev/null)
        
        if [[ "$codec" == "hevc" ]]; then
            local new_size=$(stat -c%s "$test_file")
            log_pass "GPU encoding successful (hevc codec, $new_size bytes)"
        else
            log_fail "GPU encoding failed, codec is '$codec'"
        fi
    else
        log_fail "File missing after GPU encode"
    fi
}

# ============================================================================
# TEST 4: High Threshold - Safety Feature
# Set MIN_SIZE_REDUCTION very high so replacement fails, original preserved
# ============================================================================
test_high_threshold() {
    log_test "High Threshold - Safety Feature (should NOT replace)"
    
    # Setup isolated directory
    local test_dir=$(create_test_dir "threshold")
    local test_file="$test_dir/video.mp4"
    local h265_file="$test_dir/video_h265.mp4"
    generate_test_video "$test_file" 3
    
    local original_size=$(stat -c%s "$test_file")
    local original_hash=$(md5sum "$test_file" | cut -d' ' -f1)
    log_info "Original file size: $original_size bytes"
    log_info "Setting MIN_SIZE_REDUCTION=90 (impossibly high threshold)"
    
    # Run encoder with very high threshold (90% reduction required)
    log_info "Running encoder with 90% threshold..."
    docker run --rm \
        -e MIN_SIZE_REDUCTION=90 \
        -v "$(pwd)/$test_dir:/videos" \
        "$IMAGE_NAME" 1
    
    # Verify: original should be unchanged (threshold not met)
    if [[ -f "$test_file" ]]; then
        local new_hash=$(md5sum "$test_file" | cut -d' ' -f1)
        if [[ "$original_hash" == "$new_hash" ]]; then
            log_pass "Original file preserved (safety threshold worked)"
        else
            log_fail "Original file was replaced despite high threshold"
        fi
    else
        log_fail "Original file missing"
    fi
    
    # Verify: _h265 file should be created as fallback
    if [[ -f "$h265_file" ]]; then
        log_pass "Fallback _h265 file created (safety behavior correct)"
    else
        log_fail "Expected fallback _h265 file not created"
    fi
}

# ============================================================================
# TEST 5: Dry Run Mode
# Should not modify any files
# ============================================================================
test_dry_run() {
    log_test "Dry Run Mode - No Modifications"
    
    # Setup isolated directory
    local test_dir=$(create_test_dir "dryrun")
    local test_file="$test_dir/video.mp4"
    generate_test_video "$test_file" 3
    
    local original_size=$(stat -c%s "$test_file")
    local original_hash=$(md5sum "$test_file" | cut -d' ' -f1)
    local original_mtime=$(stat -c%Y "$test_file")
    log_info "Original: size=$original_size, hash=$original_hash"
    
    # Run encoder with --dryrun
    log_info "Running encoder with --dryrun..."
    docker run --rm \
        -v "$(pwd)/$test_dir:/videos" \
        "$IMAGE_NAME" 1 --dryrun
    
    # Verify: file should be completely unchanged
    if [[ -f "$test_file" ]]; then
        local new_hash=$(md5sum "$test_file" | cut -d' ' -f1)
        local new_mtime=$(stat -c%Y "$test_file")
        
        if [[ "$original_hash" == "$new_hash" ]]; then
            log_pass "File content unchanged"
        else
            log_fail "File was modified during dry run"
        fi
        
        if [[ "$original_mtime" == "$new_mtime" ]]; then
            log_pass "File modification time unchanged"
        else
            log_fail "File mtime changed during dry run"
        fi
    else
        log_fail "Original file missing after dry run"
    fi
    
    # Verify: no new video files created
    if [[ ! -f "$test_dir/video_h265.mp4" ]]; then
        log_pass "No output video file created"
    else
        log_fail "Output file was created during dry run"
    fi
    
    # Verify: no cache file created (dry run shouldn't save cache)
    if [[ ! -f "$test_dir/filesize_cache.json" ]]; then
        log_pass "No cache file created during dry run"
    else
        log_fail "Cache file was created during dry run"
    fi
}

# ============================================================================
# Main
# ============================================================================
main() {
    echo -e "\n${BLUE}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║       H.265 Re-encoder Test Suite                         ║${NC}"
    echo -e "${BLUE}╚═══════════════════════════════════════════════════════════╝${NC}\n"
    
    check_prereqs
    setup
    
    # Run tests
    test_replace_mode
    test_no_replace_mode
    test_gpu_encoding
    test_high_threshold
    test_dry_run
    
    # Cleanup
    cleanup
    
    # Summary
    echo -e "\n${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}TEST SUMMARY${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}Passed: $PASS_COUNT${NC}"
    echo -e "${RED}Failed: $FAIL_COUNT${NC}"
    
    if [[ $FAIL_COUNT -gt 0 ]]; then
        echo -e "\n${RED}Some tests failed!${NC}"
        exit 1
    else
        echo -e "\n${GREEN}All tests passed!${NC}"
        exit 0
    fi
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
