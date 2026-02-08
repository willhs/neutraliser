---
created: 2025-09-29
updated: 2025-09-29
---

# Performance Optimization for Large Media Batch Processing

## Goal

Investigate and optimize the neutralization speed for large batches of media files (100+ movies), reducing the current processing time of ~30 minutes per movie in /Volumes/F-Movies to enable practical bulk processing of entire media libraries.

## Context

The current neutraliser implementation processes media files sequentially with comprehensive analysis and normalization. While the quality and accuracy are excellent, the performance becomes prohibitive for large media libraries. Users with collections of 100+ movies face processing times that could exceed 50+ hours for a full library scan, making bulk operations impractical.

Current bottlenecks likely include:
- Sequential file processing without parallelization
- Redundant FFmpeg analysis operations
- I/O intensive operations on external storage (/Volumes/F-Movies)
- Potentially inefficient caching strategies for large datasets

## Requirements

### Must Have
- Maintain current EBU R128 accuracy and quality standards
- Preserve existing safety features (atomic operations, rollback capability)
- Support processing 100+ media files efficiently
- Maintain compatibility with existing cache and file management systems
- Reduce per-file processing time significantly (target: <5 minutes per movie)

### Should Have
- Parallel processing capabilities for independent operations
- Optimized I/O operations for external storage volumes
- Enhanced caching strategies for bulk operations
- Progress reporting and resumable operations for long-running batches
- Memory usage optimization to prevent system overload

### Could Have
- Configurable concurrency levels based on system capabilities
- Intelligent scheduling based on file sizes and complexity
- Background processing options
- Integration with system resource monitoring

## Constraints

- Must not compromise audio quality or EBU R128 compliance
- Cannot break existing CLI interface or user workflows
- Limited by external storage I/O performance (/Volumes/F-Movies)
- Must work within existing Ruby/FFmpeg architecture
- Memory usage should remain reasonable on typical systems

## Potential Solutions

### Option 1: Parallel Processing Implementation
**Approach**: Implement concurrent processing of multiple files using Ruby's parallel processing capabilities
**Pros**:
- Significant speedup for multi-core systems
- Can process independent files simultaneously
- Relatively straightforward to implement with existing architecture
**Cons**:
- Increased memory usage
- May overwhelm slower storage systems
- Requires careful resource management

### Option 2: Pipeline Optimization
**Approach**: Optimize the analysis→decision→processing pipeline with better caching and smarter skip logic
**Pros**:
- Reduces redundant operations
- Improves cache hit rates for large batches
- Lower resource overhead than full parallelization
**Cons**:
- May have limited impact if I/O is the primary bottleneck
- Complex to implement optimal caching strategies

### Option 3: Hybrid Approach with Smart Batching
**Approach**: Combine parallel processing with optimized I/O patterns and intelligent work distribution
**Pros**:
- Addresses multiple bottlenecks simultaneously
- Can adapt to different storage performance characteristics
- Maximizes throughput while maintaining safety
**Cons**:
- Most complex to implement
- Requires extensive testing across different system configurations

## Success Criteria

- [ ] Reduce average processing time per movie from 30 minutes to <5 minutes
- [ ] Successfully process 100+ movie library in <8 hours total time
- [ ] Maintain 100% EBU R128 accuracy compared to current implementation
- [ ] Memory usage remains stable during large batch operations
- [ ] All existing safety features (atomic operations, rollback) continue to function
- [ ] Performance improvements work across different storage types (local/external/network)
- [ ] CLI interface remains backward compatible

## Investigation Areas

- Profile current performance bottlenecks (CPU, I/O, FFmpeg execution time)
- Analyze caching effectiveness for large datasets
- Evaluate parallel processing opportunities in the existing pipeline
- Test storage performance characteristics of /Volumes/F-Movies
- Review FFmpeg optimization options for batch operations

## References

- Current implementation in `lib/neutraliser/processor.rb`
- FFmpeg wrapper optimization opportunities in `lib/neutraliser/ffmpeg_wrapper.rb`
- Cache management system in `lib/neutraliser/cache_manager.rb`
- Existing performance characteristics documented in CLAUDE.md

---

## Change Log

- 2025-09-29: Task created