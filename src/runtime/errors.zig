const std = @import("std");

pub const EngineError = error{
    InvalidConfiguration,
    IncompatibleSchemaVersion,
    IncompatibleModelDimension,
    IncompatibleQuantizationVersion,
    MemoryLimitExceeded,
    QueueCapacityExceeded,
    DeadlineExceeded,
    OperationCancelled,
    StorageCorrupted,
    ChecksumMismatch,
    DiskCapacityExhausted,
    NetworkFailure,
    ProtocolViolation,
    ShardUnavailable,
    QuorumNotReached,
    GpuDispatchFailure,
    CheckpointCorrupted,
    DuplicateRecord,
    DocumentFilteredAsSpam,
    BatchQuarantined,
    NotFound,
    InvalidInput,
    OutOfMemory,
};

pub const ErrorContext = struct {
    code: EngineError,
    subsystem: []const u8,
    operation: []const u8,
    timestamp_ms: u64,
    retryable: bool,

    pub fn init(code: EngineError, subsystem: []const u8, operation: []const u8, timestamp_ms: u64) ErrorContext {
        const retryable = switch (code) {
            error.NetworkFailure,
            error.ShardUnavailable,
            error.QueueCapacityExceeded,
            error.DeadlineExceeded,
            error.GpuDispatchFailure,
            => true,
            else => false,
        };
        return .{
            .code = code,
            .subsystem = subsystem,
            .operation = operation,
            .timestamp_ms = timestamp_ms,
            .retryable = retryable,
        };
    }
};
