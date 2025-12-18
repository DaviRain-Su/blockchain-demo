# 工作量证明 (Proof of Work) 详解

## 概述

工作量证明（PoW）是一种共识机制，要求节点执行一定的计算工作才能添加新区块。这个计算工作很难完成，但结果很容易验证，从而保证区块链的安全性。

## 核心原理

### 问题定义

找到一个数值 `nonce`，使得区块的哈希值满足特定条件：

```
找到 nonce，使得:
  hash = SHA256(index || timestamp || prev_hash || data || nonce)
  hash 的前 N 位都是 0
```

### 难度与目标

难度值决定了哈希必须满足的前导零位数：

| 难度 | 二进制目标 | 十六进制示例 |
|------|-----------|-------------|
| 8 | 00000000 xxxxxxxx... | 00xxxxxx... |
| 16 | 00000000 00000000 xxxxxxxx... | 0000xxxx... |
| 24 | 00000000 00000000 00000000 xxxxxxxx... | 000000xx... |
| 32 | 00000000 00000000 00000000 00000000 xx... | 00000000xx... |

## 实现详解

### mine 方法

```zig
pub fn mine(self: *Block, difficulty: u8) void {
    // 准备目标比较数组（用于完整字节比较）
    var target: [32]u8 = undefined;
    @memset(&target, 0);
    
    // 计算需要的完整零字节数和剩余零位数
    const target_zeros = difficulty / 8;
    const remaining_bits = difficulty % 8;

    // 穷举搜索
    while (true) {
        self.hash = self.calculateHash();
        
        // 检查前 target_zeros 个字节是否全为0
        if (std.mem.eql(u8, self.hash[0..target_zeros], target[0..target_zeros])) {
            // 检查剩余的位是否为0
            if (remaining_bits == 0 or 
                (self.hash[target_zeros] >> @as(u3, @intCast(8 - remaining_bits))) == 0) {
                break;  // 找到了！
            }
        }
        self.nonce += 1;
    }
}
```

### 算法流程

```
输入: difficulty = 24

步骤1: 计算目标
┌─────────────────────────────────┐
│ target_zeros = 24 / 8 = 3      │ → 前3个字节必须是0x00
│ remaining_bits = 24 % 8 = 0    │ → 没有额外的位要求
└─────────────────────────────────┘

步骤2: 穷举搜索
┌─────────────────────────────────────────────────────────────┐
│ nonce=0: hash=7f83b165... → 第1字节=0x7f ≠ 0x00 → 继续      │
│ nonce=1: hash=4e07408a... → 第1字节=0x4e ≠ 0x00 → 继续      │
│ ...                                                          │
│ nonce=N: hash=000000ab... → 前3字节全为0 → 成功!             │
└─────────────────────────────────────────────────────────────┘
```

### 剩余位检查详解

当难度不是8的倍数时，需要检查部分字节：

```
例: difficulty = 20
target_zeros = 20 / 8 = 2      → 前2字节必须为0
remaining_bits = 20 % 8 = 4    → 第3字节的前4位必须为0

验证第3字节:
┌─────────────────────────────────────────────┐
│ 第3字节: 0x0F (二进制: 0000 1111)            │
│                       ^^^^ ^^^^              │
│                       前4位 后4位            │
│                                             │
│ 右移 (8-4)=4 位: 0x0F >> 4 = 0x00           │
│ 结果为0，满足要求 ✓                          │
└─────────────────────────────────────────────┘

┌─────────────────────────────────────────────┐
│ 第3字节: 0x1F (二进制: 0001 1111)            │
│                       ^^^^ ^^^^              │
│                                             │
│ 右移4位: 0x1F >> 4 = 0x01                   │
│ 结果不为0，不满足 ✗                          │
└─────────────────────────────────────────────┘
```

## 数学分析

### 概率计算

哈希函数的输出被视为均匀随机分布：

```
P(前N位为0) = (1/2)^N = 1 / 2^N

难度     概率              平均尝试次数
──────────────────────────────────────
8       1/256             256
16      1/65,536          65,536
20      1/1,048,576       1,048,576
24      1/16,777,216      16,777,216
32      1/4,294,967,296   4,294,967,296
```

### 时间估算

假设哈希速度为 100万次/秒：

| 难度 | 平均尝试次数 | 预期时间 |
|------|-------------|----------|
| 16 | 65,536 | 0.07秒 |
| 20 | 1,048,576 | 1秒 |
| 24 | 16,777,216 | 17秒 |
| 28 | 268,435,456 | 4.5分钟 |
| 32 | 4,294,967,296 | 72分钟 |

实际时间取决于硬件性能。

## 安全性分析

### 工作量验证

验证比计算简单得多：

```
挖矿 (困难):
  尝试 N 次哈希计算，N 约等于 2^difficulty
  时间复杂度: O(2^difficulty)

验证 (简单):
  1次哈希计算 + 前导零检查
  时间复杂度: O(1)
```

### 篡改成本

要修改历史区块，攻击者必须：

```
修改区块K的数据
     │
     ▼
重新挖掘区块K (花费时间 T)
     │
     ▼
区块K+1的prev_hash失效
     │
     ▼
重新挖掘区块K+1 (花费时间 T)
     │
     ▼
...重复直到最新区块...
     │
     ▼
总成本 ≈ (链长 - K) × T
```

只有拥有超过全网50%算力的攻击者才可能持续修改链。

## 挖矿竞争

### 多节点场景

```
节点A                         节点B
  │                             │
  ├── 开始挖index=5的区块        ├── 开始挖index=5的区块
  │                             │
  ├── nonce=0: 失败              ├── nonce=0: 失败
  ├── nonce=1: 失败              ├── nonce=1: 失败
  │   ...                        │   ...
  ├── nonce=N: 成功! ──广播──>   ├── 收到区块
  │                             │
  ├── 开始挖index=6              ├── 验证并接受
  │                             ├── 放弃当前挖矿
  │                             ├── 开始挖index=6
```

### 当前实现的问题

```zig
// main.zig miningLoop
while (true) {
    const latest = bc.getLatestBlock() orelse continue;
    // ... 创建新区块 ...
    new_block.mine(24);  // ← 这里会阻塞，期间可能收到远程区块
    
    bc.mutex.lock();
    defer bc.mutex.unlock();
    if (new_block.index == bc.blocks.items.len) {  // ← 检查是否过期
        bc.addBlockUnsafe(new_block) catch {};
    }
    // 如果过期，浪费了挖矿算力
}
```

改进：挖矿过程中定期检查是否有新区块到达。

## 难度调整

### 当前实现（固定难度）

```zig
block.mine(24); // 硬编码为24
```

### 比特币的动态调整

```
目标出块时间: 10分钟
调整周期: 每2016个区块

新难度 = 当前难度 × (目标时间 / 实际时间)

如果2016个区块用了3周（目标2周）:
  新难度 = 当前难度 × (14天 / 21天) = 当前难度 × 0.67
  → 难度降低，挖矿变快
```

### 未来改进建议

```zig
pub fn calculateNextDifficulty(
    current_difficulty: u8,
    last_blocks: []const Block,
    target_block_time: i64,  // 目标出块间隔（秒）
) u8 {
    if (last_blocks.len < 10) return current_difficulty;
    
    // 计算最近10个区块的平均出块时间
    const first = last_blocks[0].timestamp;
    const last = last_blocks[last_blocks.len - 1].timestamp;
    const actual_time = @divFloor(last - first, @intCast(i64, last_blocks.len - 1));
    
    // 调整难度
    if (actual_time < target_block_time / 2) {
        return @min(current_difficulty + 1, 64);  // 提高难度
    } else if (actual_time > target_block_time * 2) {
        return @max(current_difficulty - 1, 8);   // 降低难度
    }
    return current_difficulty;
}
```

## 哈希函数分析

### SHA-256 特性

| 特性 | 说明 | 对PoW的意义 |
|------|------|------------|
| 确定性 | 相同输入总是产生相同输出 | 可以验证 |
| 雪崩效应 | 输入微小变化导致输出完全不同 | 无法预测nonce |
| 抗碰撞 | 极难找到两个不同输入产生相同输出 | 无法作弊 |
| 单向性 | 无法从输出反推输入 | 必须穷举 |

### 哈希计算过程

```zig
pub fn calculateHash(self: *const Block) [32]u8 {
    var hasher = crypto.hash.sha2.Sha256.init(.{});
    
    // 按顺序将所有字段转换为字节并更新哈希状态
    hasher.update(std.mem.asBytes(&self.index));      // 4字节，小端序
    hasher.update(std.mem.asBytes(&self.timestamp));  // 8字节，小端序
    hasher.update(&self.prev_hash);                   // 32字节
    hasher.update(self.data);                         // 可变长度
    hasher.update(std.mem.asBytes(&self.nonce));      // 8字节，小端序
    
    return hasher.finalResult();  // 返回32字节哈希
}
```

**注意**: `std.mem.asBytes` 使用平台原生字节序（x86/ARM为小端序）。

## 性能优化思路

### 1. 批量处理

```zig
// 当前: 每次计算完整哈希
while (true) {
    self.hash = self.calculateHash();
    if (满足条件) break;
    self.nonce += 1;
}

// 优化: 预计算不变部分
var hasher = Sha256.init(.{});
hasher.update(index || timestamp || prev_hash || data);  // 只计算一次
const base_state = hasher.copy();

while (true) {
    var h = base_state.copy();
    h.update(std.mem.asBytes(&nonce));
    hash = h.finalResult();
    if (满足条件) break;
    nonce += 1;
}
```

### 2. 多线程并行

```zig
// 将nonce空间分配给多个线程
const num_threads = 8;
const range_per_thread = std.math.maxInt(u64) / num_threads;

for (0..num_threads) |i| {
    spawn(mineRange, block, i * range_per_thread, (i+1) * range_per_thread);
}
// 任一线程找到结果后通知其他线程停止
```

### 3. SIMD 优化

使用 SIMD 指令并行计算多个哈希（需要特殊的 SHA-256 实现）。

## 与其他共识机制比较

| 机制 | 优点 | 缺点 |
|------|------|------|
| **PoW** | 安全、去中心化 | 能源消耗大 |
| **PoS** (权益证明) | 节能 | 可能导致中心化 |
| **DPoS** (委托权益证明) | 高效 | 更加中心化 |
| **PBFT** | 确定性最终性 | 节点数量受限 |

## 代码示例

### 测量挖矿时间

```zig
fn measureMiningTime(difficulty: u8) void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var prev_hash: [32]u8 = undefined;
    @memset(&prev_hash, 0);

    var block = Block.init(allocator, 0, std.time.timestamp(), prev_hash, "test");
    defer block.deinit(allocator);

    const start = std.time.nanoTimestamp();
    block.mine(difficulty);
    const end = std.time.nanoTimestamp();

    const ms = @divFloor(end - start, 1_000_000);
    std.debug.print("Difficulty {}: {} ms, nonce={}\n", .{difficulty, ms, block.nonce});
}

pub fn main() void {
    for ([_]u8{16, 20, 24, 28}) |diff| {
        measureMiningTime(diff);
    }
}
```

### 验证工作量证明

```zig
fn verifyProofOfWork(block: *const Block, difficulty: u8) bool {
    // 重新计算哈希
    const calculated = block.calculateHash();
    if (!std.mem.eql(u8, &block.hash, &calculated)) {
        return false;  // 哈希不匹配
    }
    
    // 检查难度
    const target_zeros = difficulty / 8;
    for (block.hash[0..target_zeros]) |byte| {
        if (byte != 0) return false;
    }
    
    const remaining_bits = difficulty % 8;
    if (remaining_bits > 0) {
        if ((block.hash[target_zeros] >> @intCast(u3, 8 - remaining_bits)) != 0) {
            return false;
        }
    }
    
    return true;
}
```
