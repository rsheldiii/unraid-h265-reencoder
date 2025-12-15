# Use Debian-based Ruby image for better compatibility
FROM ruby:3.2-slim

# Set metadata labels
LABEL maintainer="H.265 Re-encode Container"
LABEL description="Automated H.265/HEVC video re-encoding container for Unraid"

# Install ffmpeg and required dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    ffmpeg \
    && rm -rf /var/lib/apt/lists/*

# Create application directory
WORKDIR /app

# Copy the Ruby script
COPY reencode_largest.rb /app/reencode_largest.rb

# Make script executable
RUN chmod +x /app/reencode_largest.rb

# Create videos directory (mount point for user's video files)
RUN mkdir -p /videos

# Set working directory to /videos so cache file is created there by default
WORKDIR /videos

# Set default environment variables (can be overridden by user)
ENV CRF_VALUE=20
ENV PRESET=medium
ENV TARGET_DIRECTORY=/videos
ENV VIDEO_EXTENSIONS=.mp4,.mkv,.avi,.wmv,.mov,.flv,.m4v
ENV CACHE_FILE=/videos/filesize_cache.json
ENV LOG_FILE=/videos/h265_encoder.log
ENV MIN_SIZE_REDUCTION=10
ENV USE_GPU=false

# Use ENTRYPOINT for the script and CMD for default arguments
# This allows users to pass additional arguments via docker run
# Default behavior: process 1 video and replace original (safe with size checks)
# Use --no-replace to keep original files
ENTRYPOINT ["/app/reencode_largest.rb"]
CMD ["1"]

