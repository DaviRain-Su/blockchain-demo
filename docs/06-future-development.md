# 后续功能开发指南

## 概述

本文档描述了项目的可扩展方向和实现建议。每个功能都包含设计思路、数据结构和实现要点。

## 功能优先级

| 优先级 | 功能 | 复杂度 | 依赖 |
|--------|------|--------|------|
| 1 | 交易系统 | 中 | 无 |
| 2 | 钱包/密钥对 | 中 | 无 |
| 3 | 区块链同步 | 中 | 无 |
| 4 | UTXO模型 | 高 | 交易系统 |
| 5 | Merkle树 | 中 | 交易系统 |
| 6 | 动态难度调整 | 低 | 无 |
| 7 | 持久化存储 | 中 | 无 |
| 8 | 消息帧协议 | 低 | 无 |
| 9 | 最长链规则 | 高 | 区块链同步 |
| 10 | 节点发现 | 高 | 无 |

---

## 1. 交易系统

### 目标

将区块的 `data` 字段从简单字符串改为结构化的交易列表。

### 数据结构

```zig
// transaction.zig

pub const Transaction = struct {
    id: [32]u8,              // 交易哈希（唯一标识）
    sender: [32]u8,          // 发送者公钥
    receiver: [32]u8,        // 接收者公钥
    amount: u64,             // 交易金额
    timestamp: i64,          // 交易时间
    signature: [64]u8,       // 发送者签名
    
    pub fn init(sender: [32]u8, receiver: [32]u8, amount: u64) Transaction {
        return Transaction{
            .id = undefined,  // 待计算
            .sender = sender,
            .receiver = receiver,
            .amount = amount,
            .timestamp = std.time.timestamp(),
            .signature = undefined,  // 待签名
        };
    }
    
    pub fn calculateId(self: *const Transaction) [32]u8 {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(&self.sender);
        hasher.update(&self.receiver);
        hasher.update(std.mem.asBytes(&self.amount));
        hasher.update(std.mem.asBytes(&self.timestamp));
        return hasher.finalResult();
    }
    
    pub fn sign(self: *Transaction, private_key: [32]u8) void {
        // 使用Ed25519签名
        self.id = self.calculateId();
        self.signature = Ed25519.sign(self.id, private_key);
    }
    
    pub fn verify(self: *const Transaction) bool {
        // 验证签名
        return Ed25519.verify(self.signature, self.id, self.sender);
    }
};
```

### 修改Block结构

```zig
// blockchain.zig 修改

pub const Block = struct {
    index: u32,
    timestamp: i64,
    prev_hash: [32]u8,
    transactions: []Transaction,  // 替换 data
    merkle_root: [32]u8,          // 新增
    hash: [32]u8,
    nonce: u64,
    
    pub fn calculateHash(self: *const Block) [32]u8 {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(std.mem.asBytes(&self.index));
        hasher.update(std.mem.asBytes(&self.timestamp));
        hasher.update(&self.prev_hash);
        hasher.update(&self.merkle_root);  // 使用merkle根
        hasher.update(std.mem.asBytes(&self.nonce));
        return hasher.finalResult();
    }
};
```

### 交易池

```zig
pub const TransactionPool = struct {
    allocator: std.mem.Allocator,
    pending: std.ArrayList(Transaction),
    mutex: std.Thread.Mutex,
    
    pub fn addTransaction(self: *TransactionPool, tx: Transaction) !void {
        if (!tx.verify()) return error.InvalidSignature;
        
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.pending.append(self.allocator, tx);
    }
    
    pub fn getTransactionsForBlock(self: *TransactionPool, max_count: usize) []Transaction {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const count = @min(self.pending.items.len, max_count);
        const txs = self.allocator.alloc(Transaction, count) catch return &.{};
        @memcpy(txs, self.pending.items[0..count]);
        
        // 从池中移除
        self.pending.replaceRange(0, count, &.{}) catch {};
        return txs;
    }
};
```

### 序列化格式

```
Transaction 二进制格式:
┌───────┬─────────┬──────────┬────────┬───────────┬───────────┐
│ id    │ sender  │ receiver │ amount │ timestamp │ signature │
│ 32B   │ 32B     │ 32B      │ 8B LE  │ 8B LE     │ 64B       │
└───────┴─────────┴──────────┴────────┴───────────┴───────────┘
总计: 176 字节

Block 中的 transactions:
┌──────────────┬──────────────────────────────────────────────┐
│ tx_count (4B)│ Transaction[0] ... Transaction[n]           │
└──────────────┴──────────────────────────────────────────────┘
```

---

## 2. 钱包/密钥对

### 目标

实现密钥对生成和管理，用于签名和验证交易。

### 数据结构

```zig
// wallet.zig

const Ed25519 = std.crypto.sign.Ed25519;

pub const Wallet = struct {
    public_key: [32]u8,
    private_key: [64]u8,  // Ed25519扩展私钥
    
    pub fn generate() Wallet {
        const key_pair = Ed25519.KeyPair.create(null);
        return Wallet{
            .public_key = key_pair.public_key,
            .private_key = key_pair.secret_key,
        };
    }
    
    pub fn fromSeed(seed: [32]u8) Wallet {
        const key_pair = Ed25519.KeyPair.create(seed);
        return Wallet{
            .public_key = key_pair.public_key,
            .private_key = key_pair.secret_key,
        };
    }
    
    pub fn sign(self: *const Wallet, message: []const u8) [64]u8 {
        return Ed25519.sign(message, self.private_key, null);
    }
    
    pub fn getAddress(self: *const Wallet) [32]u8 {
        // 地址 = 公钥的哈希（简化版，实际可能用不同编码）
        return std.crypto.hash.sha2.Sha256.hash(&self.public_key);
    }
};

pub fn verifySignature(public_key: [32]u8, message: []const u8, signature: [64]u8) bool {
    Ed25519.verify(signature, message, public_key) catch return false;
    return true;
}
```

### 钱包文件格式

```json
{
    "version": 1,
    "encrypted": false,
    "public_key": "base64编码的公钥",
    "private_key": "base64编码的私钥（生产环境应加密）"
}
```

### 与交易系统集成

```zig
pub fn createTransaction(
    wallet: *const Wallet,
    receiver: [32]u8,
    amount: u64,
) Transaction {
    var tx = Transaction.init(wallet.public_key, receiver, amount);
    tx.sign(wallet.private_key);
    return tx;
}
```

---

## 3. 区块链同步

### 目标

新节点加入时，从其他节点获取完整的区块链历史。

### 消息类型扩展

```zig
pub const MessageType = enum(u8) {
    block = 0,              // 单个新区块
    request_blocks = 1,     // 请求区块（指定起始索引）
    response_blocks = 2,    // 响应区块列表
    get_height = 3,         // 请求链高度
    height = 4,             // 返回链高度
};

pub const Message = union(MessageType) {
    block: Block,
    request_blocks: struct {
        start_index: u32,
        count: u32,
    },
    response_blocks: []Block,
    get_height: void,
    height: u32,
};
```

### 同步流程

```
新节点A                           现有节点B
    │                                  │
    ├── get_height ───────────────────>│
    │                                  │
    │<──────────────────── height: 100 ─┤
    │                                  │
    │ (A的高度是0，需要同步100个区块)     │
    │                                  │
    ├── request_blocks(0, 50) ────────>│
    │                                  │
    │<─────────── response_blocks[0..49]─┤
    │                                  │
    │ (验证并添加区块0-49)              │
    │                                  │
    ├── request_blocks(50, 50) ───────>│
    │                                  │
    │<────────── response_blocks[50..99]─┤
    │                                  │
    │ (验证并添加区块50-99)             │
    │                                  │
    │ 同步完成，开始正常挖矿             │
```

### 实现要点

```zig
fn handleConnection(self: *Node, stream: std.net.Stream, blockchain: *Blockchain) void {
    // ... 现有代码 ...
    
    switch (msg) {
        .get_height => {
            blockchain.mutex.lock();
            const height = @intCast(u32, blockchain.blocks.items.len);
            blockchain.mutex.unlock();
            
            const response = serializeMessage(self.allocator, .{ .height = height });
            defer self.allocator.free(response);
            _ = stream.write(response) catch {};
        },
        
        .request_blocks => |req| {
            blockchain.mutex.lock();
            defer blockchain.mutex.unlock();
            
            const end = @min(req.start_index + req.count, blockchain.blocks.items.len);
            const blocks = blockchain.blocks.items[req.start_index..end];
            
            const response = serializeMessage(self.allocator, .{ .response_blocks = blocks });
            defer self.allocator.free(response);
            _ = stream.write(response) catch {};
        },
        
        .response_blocks => |blocks| {
            for (blocks) |block| {
                // 验证并添加
                if (isValidBlock(&block, blockchain)) {
                    blockchain.addBlockUnsafe(block) catch {};
                }
            }
        },
        
        // ... 其他消息处理 ...
    }
}
```

---

## 4. UTXO模型

### 目标

实现未花费交易输出（Unspent Transaction Output）模型，准确追踪余额。

### 数据结构

```zig
// utxo.zig

pub const TxInput = struct {
    tx_id: [32]u8,      // 引用的交易ID
    output_index: u32,  // 输出索引
    signature: [64]u8,  // 解锁签名
};

pub const TxOutput = struct {
    amount: u64,
    recipient: [32]u8,  // 接收者公钥
};

pub const Transaction = struct {
    id: [32]u8,
    inputs: []TxInput,
    outputs: []TxOutput,
    timestamp: i64,
};

pub const UTXO = struct {
    tx_id: [32]u8,
    output_index: u32,
    output: TxOutput,
};

pub const UTXOSet = struct {
    allocator: std.mem.Allocator,
    // 使用 HashMap: (tx_id, output_index) -> TxOutput
    utxos: std.AutoHashMap(UTXOKey, TxOutput),
    
    pub fn getBalance(self: *const UTXOSet, address: [32]u8) u64 {
        var balance: u64 = 0;
        var iter = self.utxos.iterator();
        while (iter.next()) |entry| {
            if (std.mem.eql(u8, &entry.value_ptr.recipient, &address)) {
                balance += entry.value_ptr.amount;
            }
        }
        return balance;
    }
    
    pub fn applyTransaction(self: *UTXOSet, tx: *const Transaction) !void {
        // 移除消费的UTXO
        for (tx.inputs) |input| {
            _ = self.utxos.remove(.{ .tx_id = input.tx_id, .output_index = input.output_index });
        }
        // 添加新的UTXO
        for (tx.outputs, 0..) |output, i| {
            try self.utxos.put(.{ .tx_id = tx.id, .output_index = @intCast(u32, i) }, output);
        }
    }
};
```

### 交易验证

```zig
pub fn validateTransaction(tx: *const Transaction, utxo_set: *const UTXOSet) !void {
    var input_sum: u64 = 0;
    var output_sum: u64 = 0;
    
    // 验证所有输入
    for (tx.inputs) |input| {
        // 1. 检查UTXO是否存在
        const utxo = utxo_set.utxos.get(.{ .tx_id = input.tx_id, .output_index = input.output_index }) 
            orelse return error.UTXONotFound;
        
        // 2. 验证签名
        if (!verifySignature(utxo.recipient, &input.tx_id, input.signature)) {
            return error.InvalidSignature;
        }
        
        input_sum += utxo.amount;
    }
    
    // 计算输出总和
    for (tx.outputs) |output| {
        output_sum += output.amount;
    }
    
    // 输入必须 >= 输出（差额为手续费）
    if (input_sum < output_sum) {
        return error.InsufficientFunds;
    }
}
```

---

## 5. Merkle树

### 目标

使用Merkle树高效地验证区块中的交易。

### 数据结构

```zig
// merkle.zig

pub const MerkleTree = struct {
    allocator: std.mem.Allocator,
    root: [32]u8,
    leaves: [][32]u8,
    
    pub fn build(allocator: std.mem.Allocator, transactions: []const Transaction) !MerkleTree {
        if (transactions.len == 0) {
            var empty: [32]u8 = undefined;
            @memset(&empty, 0);
            return MerkleTree{ .allocator = allocator, .root = empty, .leaves = &.{} };
        }
        
        // 计算叶子节点（交易哈希）
        var leaves = try allocator.alloc([32]u8, transactions.len);
        for (transactions, 0..) |tx, i| {
            leaves[i] = tx.id;
        }
        
        // 构建树
        var current_level = leaves;
        while (current_level.len > 1) {
            const next_len = (current_level.len + 1) / 2;
            var next_level = try allocator.alloc([32]u8, next_len);
            
            var i: usize = 0;
            while (i < current_level.len) : (i += 2) {
                if (i + 1 < current_level.len) {
                    next_level[i / 2] = hashPair(current_level[i], current_level[i + 1]);
                } else {
                    next_level[i / 2] = hashPair(current_level[i], current_level[i]);
                }
            }
            
            if (current_level.ptr != leaves.ptr) {
                allocator.free(current_level);
            }
            current_level = next_level;
        }
        
        const root = current_level[0];
        allocator.free(current_level);
        
        return MerkleTree{
            .allocator = allocator,
            .root = root,
            .leaves = leaves,
        };
    }
    
    fn hashPair(a: [32]u8, b: [32]u8) [32]u8 {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(&a);
        hasher.update(&b);
        return hasher.finalResult();
    }
};
```

### Merkle证明

```
                    Root
                   /    \
                 H12    H34
                /  \    /  \
              H1   H2  H3   H4
              |    |   |    |
             TX1  TX2 TX3  TX4

验证TX2在树中:
证明路径: [H1, H34]
验证: hash(H1, hash(TX2)) == H12
      hash(H12, H34) == Root
```

---

## 6. 动态难度调整

### 目标

根据实际出块时间自动调整挖矿难度。

### 实现

```zig
// difficulty.zig

pub const DifficultyAdjuster = struct {
    target_block_time: i64,     // 目标出块时间（秒）
    adjustment_interval: u32,   // 调整间隔（区块数）
    min_difficulty: u8,
    max_difficulty: u8,
    
    pub fn calculateNextDifficulty(
        self: *const DifficultyAdjuster,
        blockchain: *const Blockchain,
        current_difficulty: u8,
    ) u8 {
        const len = blockchain.blocks.items.len;
        if (len < self.adjustment_interval) {
            return current_difficulty;
        }
        
        // 计算最近 adjustment_interval 个区块的实际时间
        const start_block = &blockchain.blocks.items[len - self.adjustment_interval];
        const end_block = &blockchain.blocks.items[len - 1];
        const actual_time = end_block.timestamp - start_block.timestamp;
        const expected_time = self.target_block_time * @intCast(i64, self.adjustment_interval - 1);
        
        // 调整难度
        if (actual_time < expected_time / 2) {
            // 太快，增加难度
            return @min(current_difficulty + 1, self.max_difficulty);
        } else if (actual_time > expected_time * 2) {
            // 太慢，降低难度
            return @max(current_difficulty - 1, self.min_difficulty);
        }
        
        return current_difficulty;
    }
};
```

### 在区块中存储难度

```zig
pub const Block = struct {
    // ... 其他字段 ...
    difficulty: u8,  // 新增：记录挖此区块时的难度
    
    pub fn calculateHash(self: *const Block) [32]u8 {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        // ... 其他字段 ...
        hasher.update(std.mem.asBytes(&self.difficulty));  // 包含难度
        hasher.update(std.mem.asBytes(&self.nonce));
        return hasher.finalResult();
    }
};
```

---

## 7. 持久化存储

### 目标

将区块链数据持久化到磁盘，程序重启后可恢复。

### 文件格式

```
blockchain.dat:
┌────────────────────────────────────┐
│ Magic Number (4B): "BLKC"          │
│ Version (4B): 1                    │
│ Block Count (4B)                   │
├────────────────────────────────────┤
│ Block 0 (变长)                      │
├────────────────────────────────────┤
│ Block 1 (变长)                      │
├────────────────────────────────────┤
│ ...                                │
└────────────────────────────────────┘
```

### 实现

```zig
// storage.zig

pub const BlockchainStorage = struct {
    file_path: []const u8,
    
    pub fn save(self: *const BlockchainStorage, blockchain: *const Blockchain) !void {
        const file = try std.fs.cwd().createFile(self.file_path, .{});
        defer file.close();
        
        var writer = file.writer();
        
        // 写入头部
        try writer.writeAll("BLKC");
        try writer.writeInt(u32, 1, .little);  // version
        try writer.writeInt(u32, @intCast(u32, blockchain.blocks.items.len), .little);
        
        // 写入每个区块
        for (blockchain.blocks.items) |block| {
            try self.writeBlock(writer, &block);
        }
    }
    
    pub fn load(self: *const BlockchainStorage, allocator: std.mem.Allocator) !Blockchain {
        const file = try std.fs.cwd().openFile(self.file_path, .{});
        defer file.close();
        
        var reader = file.reader();
        
        // 验证头部
        var magic: [4]u8 = undefined;
        _ = try reader.readAll(&magic);
        if (!std.mem.eql(u8, &magic, "BLKC")) {
            return error.InvalidFileFormat;
        }
        
        const version = try reader.readInt(u32, .little);
        if (version != 1) return error.UnsupportedVersion;
        
        const block_count = try reader.readInt(u32, .little);
        
        // 读取区块
        var blockchain = Blockchain.init(allocator);
        for (0..block_count) |_| {
            const block = try self.readBlock(reader, allocator);
            try blockchain.blocks.append(allocator, block);
        }
        
        return blockchain;
    }
    
    fn writeBlock(self: *const BlockchainStorage, writer: anytype, block: *const Block) !void {
        try writer.writeInt(u32, block.index, .little);
        try writer.writeInt(i64, block.timestamp, .little);
        try writer.writeAll(&block.prev_hash);
        try writer.writeInt(u32, @intCast(u32, block.data.len), .little);
        try writer.writeAll(block.data);
        try writer.writeAll(&block.hash);
        try writer.writeInt(u64, block.nonce, .little);
    }
    
    fn readBlock(self: *const BlockchainStorage, reader: anytype, allocator: std.mem.Allocator) !Block {
        // ... 读取逻辑 ...
    }
};
```

---

## 8. 消息帧协议

### 目标

解决TCP流的消息边界问题。

### 协议格式

```
每个消息帧:
┌──────────────┬──────────────────────────────────┐
│ Length (4B)  │ Payload (变长)                    │
│ 小端序        │ 类型字节 + 消息数据                │
└──────────────┴──────────────────────────────────┘
```

### 实现

```zig
// framing.zig

pub fn writeFrame(writer: anytype, data: []const u8) !void {
    try writer.writeInt(u32, @intCast(u32, data.len), .little);
    try writer.writeAll(data);
}

pub fn readFrame(allocator: std.mem.Allocator, reader: anytype) ![]u8 {
    const length = try reader.readInt(u32, .little);
    if (length > 1024 * 1024) {  // 限制1MB
        return error.FrameTooLarge;
    }
    
    const buffer = try allocator.alloc(u8, length);
    errdefer allocator.free(buffer);
    
    const bytes_read = try reader.readAll(buffer);
    if (bytes_read != length) {
        return error.UnexpectedEof;
    }
    
    return buffer;
}
```

---

## 9. 最长链规则

### 目标

处理区块链分叉，选择工作量最大的链。

### 实现思路

```zig
pub fn handleFork(blockchain: *Blockchain, new_blocks: []const Block) !void {
    // 找到分叉点
    var fork_point: ?usize = null;
    for (new_blocks, 0..) |block, i| {
        if (i < blockchain.blocks.items.len) {
            if (!std.mem.eql(u8, &block.hash, &blockchain.blocks.items[i].hash)) {
                fork_point = i;
                break;
            }
        } else {
            fork_point = i;
            break;
        }
    }
    
    if (fork_point == null) return;  // 无分叉
    
    // 比较总工作量
    const current_work = calculateTotalWork(blockchain.blocks.items[fork_point.?..]);
    const new_work = calculateTotalWork(new_blocks[fork_point.?..]);
    
    if (new_work > current_work) {
        // 切换到新链
        // 1. 移除旧区块
        // 2. 添加新区块
        // 3. 更新UTXO集（如果有）
    }
}

fn calculateTotalWork(blocks: []const Block) u256 {
    var total: u256 = 0;
    for (blocks) |block| {
        // 工作量 = 2^difficulty
        total += @as(u256, 1) << block.difficulty;
    }
    return total;
}
```

---

## 10. 节点发现

### 目标

自动发现和连接网络中的其他节点。

### 方法

1. **种子节点**: 硬编码一些初始节点地址
2. **节点交换**: 向已连接节点请求其他节点列表
3. **DHT**: 实现分布式哈希表（复杂）

### 简单实现

```zig
pub const MessageType = enum(u8) {
    // ... 现有类型 ...
    get_peers = 5,      // 请求节点列表
    peers = 6,          // 返回节点列表
};

pub const PeerInfo = struct {
    ip: [4]u8,          // IPv4地址
    port: u16,
};

// 处理节点交换
.get_peers => {
    self.mutex.lock();
    defer self.mutex.unlock();
    
    var peer_list: [MAX_PEERS]PeerInfo = undefined;
    var count: usize = 0;
    for (self.peers.items) |peer| {
        if (count >= MAX_PEERS) break;
        peer_list[count] = extractPeerInfo(peer.address);
        count += 1;
    }
    
    const response = serializeMessage(.{ .peers = peer_list[0..count] });
    _ = stream.write(response) catch {};
},

.peers => |peer_list| {
    for (peer_list) |info| {
        const address = std.net.Address.initIp4(info.ip, info.port);
        self.connectToPeer(address) catch continue;
    }
},
```

---

## 开发建议

### 文件组织

```
src/
├── main.zig              # 入口
├── blockchain.zig        # 区块和链
├── transaction.zig       # 交易 (新增)
├── wallet.zig            # 钱包 (新增)
├── utxo.zig              # UTXO集 (新增)
├── merkle.zig            # Merkle树 (新增)
├── network.zig           # 网络层
├── framing.zig           # 消息帧 (新增)
├── storage.zig           # 持久化 (新增)
├── difficulty.zig        # 难度调整 (新增)
└── root.zig              # 库导出
```

### 测试策略

每个新模块都应包含测试：

```zig
test "transaction signature" {
    const wallet = Wallet.generate();
    var tx = Transaction.init(wallet.public_key, receiver, 100);
    tx.sign(wallet.private_key);
    try std.testing.expect(tx.verify());
}

test "merkle root" {
    // ...
}
```

### 渐进式开发

1. 先实现核心功能（交易、钱包）
2. 添加测试
3. 集成到主程序
4. 添加网络同步
5. 最后添加高级功能（UTXO、Merkle等）
