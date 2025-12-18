const std = @import("std");
const crypto = std.crypto;

pub const Block = struct {
    index: u32,
    timestamp: i64,
    prev_hash: [32]u8,
    data: []const u8,
    hash: [32]u8,
    nonce: u64,

    pub fn init(allocator: std.mem.Allocator, index: u32, timestamp: i64, prev_hash: [32]u8, data: []const u8) Block {
        return Block{
            .index = index,
            .timestamp = timestamp,
            .prev_hash = prev_hash,
            .data = allocator.dupe(u8, data) catch unreachable,
            .hash = undefined,
            .nonce = 0,
        };
    }

    pub fn deinit(self: *Block, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }

    pub fn calculateHash(self: *const Block) [32]u8 {
        var hasher = crypto.hash.sha2.Sha256.init(.{});
        hasher.update(std.mem.asBytes(&self.index));
        hasher.update(std.mem.asBytes(&self.timestamp));
        hasher.update(&self.prev_hash);
        hasher.update(self.data);
        hasher.update(std.mem.asBytes(&self.nonce));
        return hasher.finalResult();
    }

    pub fn mine(self: *Block, difficulty: u8) void {
        var target: [32]u8 = undefined;
        @memset(&target, 0);
        const target_zeros = difficulty / 8;
        const remaining_bits = difficulty % 8;

        while (true) {
            self.hash = self.calculateHash();
            if (std.mem.eql(u8, self.hash[0..target_zeros], target[0..target_zeros])) {
                if (remaining_bits == 0 or (self.hash[target_zeros] >> @as(u3, @intCast(8 - remaining_bits))) == 0) {
                    break;
                }
            }
            self.nonce += 1;
        }
    }
};

pub const Blockchain = struct {
    allocator: std.mem.Allocator,
    blocks: std.ArrayList(Block),
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator) Blockchain {
        return Blockchain{
            .allocator = allocator,
            .blocks = std.ArrayList(Block).initCapacity(allocator, 0) catch unreachable,
            .mutex = std.Thread.Mutex{},
        };
    }

    pub fn deinit(self: *Blockchain) void {
        for (self.blocks.items) |*block| {
            block.deinit(self.allocator);
        }
        self.blocks.deinit(self.allocator);
    }

    /// 创建固定的创世块（所有节点使用相同的创世块）
    pub fn createGenesisBlock(self: *Blockchain, data: []const u8) !void {
        // 使用固定时间戳确保所有节点创世块相同
        const fixed_timestamp: i64 = 1700000000; // 固定时间戳
        var prev_hash: [32]u8 = undefined;
        @memset(&prev_hash, 0);

        var block = Block.init(self.allocator, 0, fixed_timestamp, prev_hash, data);
        block.mine(24); // difficulty 24
        try self.blocks.append(self.allocator, block);
    }

    pub fn addBlock(self: *Blockchain, data: []const u8) !void {
        const prev_block = &self.blocks.items[self.blocks.items.len - 1];
        const timestamp = std.time.timestamp();

        var block = Block.init(self.allocator, prev_block.index + 1, timestamp, prev_block.hash, data);
        block.mine(24); // difficulty 24
        try self.blocks.append(self.allocator, block);
    }

    pub fn isValid(self: *const Blockchain) bool {
        for (self.blocks.items, 0..) |*block, i| {
            if (i == 0) {
                // Genesis block
                continue;
            }
            const prev_block = &self.blocks.items[i - 1];
            if (!std.mem.eql(u8, &block.prev_hash, &prev_block.hash)) {
                return false;
            }
            if (!std.mem.eql(u8, &block.hash, &block.calculateHash())) {
                return false;
            }
        }
        return true;
    }

    pub fn getLatestBlock(self: *Blockchain) ?*Block {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.blocks.items.len == 0) return null;
        return &self.blocks.items[self.blocks.items.len - 1];
    }

    pub fn addBlockUnsafe(self: *Blockchain, block: Block) !void {
        try self.blocks.append(self.allocator, block);
    }
};
