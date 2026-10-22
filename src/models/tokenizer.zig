const std = @import("std");
const hashing = @import("../util/hashing.zig");

pub const CLS_TOKEN_ID: u32 = 1;
pub const SEP_TOKEN_ID: u32 = 2;
pub const PAD_TOKEN_ID: u32 = 0;
pub const UNK_TOKEN_ID: u32 = 3;

pub const TokenSpan = struct {
    token_id: u32,
    byte_offset: u32,
    byte_len: u16,
    is_subword: bool,
};

pub const SubwordTokenizer = struct {
    vocab_size: u32,
    max_seq_len: u32,

    pub fn init(vocab_size: u32, max_seq_len: u32) SubwordTokenizer {
        return .{
            .vocab_size = @max(1024, vocab_size),
            .max_seq_len = @max(16, max_seq_len),
        };
    }

    pub fn encodeText(
        self: SubwordTokenizer,
        allocator: std.mem.Allocator,
        text: []const u8,
    ) ![]TokenSpan {
        var spans = std.ArrayList(TokenSpan).init(allocator);
        errdefer spans.deinit();

        try spans.append(.{
            .token_id = CLS_TOKEN_ID,
            .byte_offset = 0,
            .byte_len = 0,
            .is_subword = false,
        });

        var i: usize = 0;
        while (i < text.len and spans.items.len + 1 < self.max_seq_len) {
            while (i < text.len and std.ascii.isWhitespace(text[i])) : (i += 1) {}
            if (i >= text.len) break;

            const start = i;
            if (std.ascii.isAlphanumeric(text[i])) {
                while (i < text.len and std.ascii.isAlphanumeric(text[i]) and (i - start) < 24) : (i += 1) {}
            } else {
                i += 1;
            }
            const raw_word = text[start..i];
            if (raw_word.len <= 8) {
                const tid = self.hashTokenToVocab(raw_word, 0x13579bdf);
                try spans.append(.{
                    .token_id = tid,
                    .byte_offset = @intCast(start),
                    .byte_len = @intCast(raw_word.len),
                    .is_subword = false,
                });
            } else {
                var sub_pos: usize = 0;
                var first = true;
                while (sub_pos < raw_word.len and spans.items.len + 1 < self.max_seq_len) {
                    const chunk_len = @min(@as(usize, 6), raw_word.len - sub_pos);
                    const sub_slice = raw_word[sub_pos .. sub_pos + chunk_len];
                    const tid = self.hashTokenToVocab(sub_slice, if (first) 0x13579bdf else 0x2468ace0);
                    try spans.append(.{
                        .token_id = tid,
                        .byte_offset = @intCast(start + sub_pos),
                        .byte_len = @intCast(chunk_len),
                        .is_subword = !first,
                    });
                    sub_pos += chunk_len;
                    first = false;
                }
            }
        }

        try spans.append(.{
            .token_id = SEP_TOKEN_ID,
            .byte_offset = @intCast(text.len),
            .byte_len = 0,
            .is_subword = false,
        });

        return spans.toOwnedSlice();
    }

    pub fn hashTokenToVocab(self: SubwordTokenizer, token: []const u8, seed: u64) u32 {
        var lower_buf: [32]u8 = undefined;
        const len = @min(token.len, lower_buf.len);
        for (token[0..len], 0..) |ch, idx| {
            lower_buf[idx] = std.ascii.toLower(ch);
        }
        const h = hashing.wyhash64(lower_buf[0..len], seed);
        const usable = self.vocab_size - 16;
        return 16 + @as(u32, @intCast(h % usable));
    }
};
