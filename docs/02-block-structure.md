# 区块结构详解

## 概述

区块（Block）是区块链的基本数据单元。每个区块包含一组数据，并通过密码学哈希与前一个区块链接，形成不可篡改的链式结构。

## 数据结构

### Block 结构定义

```zig
pub const Block = struct {
    index: u32,           // 区块索引（高度）
    timestamp: i64,       // 创建时间戳（Unix时间）
    prev_hash: [32]u8,    // 前一区块的哈希值
    data: []const u8,     // 区块数据（当前为字符串）
    hash: [32]u8,         // 本区块的哈希值
    nonce: u64,           // 工作量证明随机数
};
```

### 字段说明

| 字段 | 类型 | 大小 | 说明 |
|------|------|------|------|
| index | u32 | 4字节 | 区块在链中的位置，创世块为0 |
| timestamp | i64 | 8字节 | 区块创建的Unix时间戳 |
| prev_hash | [32]u8 | 32字节 | 前一区块的SHA-256哈希 |
| data | []const u8 | 可变 | 区块携带的数据（动态分配） |
| hash | [32]u8 | 32字节 | 本区块的SHA-256哈希 |
| nonce | u64 | 8字节 | 挖矿过程中的随机数 |

### 内存布局

```
Block 实例内存布局:
┌─────────────────────────────────────────────────────────────┐
│ index (4字节) │ 填充 (4字节) │      timestamp (8字节)        │
├─────────────────────────────────────────────────────────────┤
│                     prev_hash (32字节)                       │
├─────────────────────────────────────────────────────────────┤
│        data.ptr (8字节)       │      data.len (8字节)        │
├─────────────────────────────────────────────────────────────┤
│                       hash (32字节)                          │
├─────────────────────────────────────────────────────────────┤
│                       nonce (8字节)                          │
└─────────────────────────────────────────────────────────────┘

注: data 字段是切片，指向堆上动态分配的内存
```

## 区块方法

### init - 初始化区块

```zig
pub fn init(
    allocator: std.mem.Allocator,
    index: u32,
    timestamp: i64,
    prev_hash: [32]u8,
    data: []const u8
) Block
```

**功能**: 创建新的区块实例

**参数**:
- `allocator`: 内存分配器，用于复制数据
- `index`: 区块索引
- `timestamp`: 时间戳
- `prev_hash`: 前一区块哈希
- `data`: 区块数据

**行为**:
1. 使用分配器复制 `data` 到新内存（`allocator.dupe`）
2. 初始化 `hash` 为未定义状态
3. 初始化 `nonce` 为 0

**注意**: `hash` 字段在 `init` 后是未定义的，需要调用 `mine()` 来计算。

### deinit - 销毁区块

```zig
pub fn deinit(self: *Block, allocator: std.mem.Allocator) void
```

**功能**: 释放区块占用的动态内存

**参数**:
- `allocator`: 必须是创建时使用的同一分配器

**行为**: 释放 `data` 字段指向的内存

### calculateHash - 计算哈希

```zig
pub fn calculateHash(self: *const Block) [32]u8
```

**功能**: 计算区块的SHA-256哈希值

**算法**:
```
hash = SHA256(index || timestamp || prev_hash || data || nonce)
```

**实现细节**:
```zig
var hasher = crypto.hash.sha2.Sha256.init(.{});
hasher.update(std.mem.asBytes(&self.index));      // 4字节
hasher.update(std.mem.asBytes(&self.timestamp));  // 8字节
hasher.update(&self.prev_hash);                   // 32字节
hasher.update(self.data);                         // 可变长度
hasher.update(std.mem.asBytes(&self.nonce));      // 8字节
return hasher.finalResult();
```

**注意**: 使用 `std.mem.asBytes` 将整数转换为字节序列，这是平台相关的（小端序）。

### mine - 工作量证明挖矿

```zig
pub fn mine(self: *Block, difficulty: u8) void
```

**功能**: 执行工作量证明，找到满足难度要求的nonce

**参数**:
- `difficulty`: 难度值，表示哈希前导零的位数

**算法流程**:

```
┌─────────────────┐
│ 设置目标: 前     │
│ difficulty 位   │
│ 必须为0         │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ nonce = 0       │
└────────┬────────┘
         │
         ▼
┌─────────────────┐     否
│ 计算哈希        │◄─────────┐
└────────┬────────┘          │
         │                   │
         ▼                   │
┌─────────────────┐          │
│ 检查前导零位数   │          │
│ >= difficulty?  │          │
└────────┬────────┘          │
         │                   │
    是   │   否              │
         │    └──────────────┤
         ▼                   │
┌─────────────────┐   ┌──────┴──────┐
│ 保存哈希并返回   │   │ nonce += 1  │
└─────────────────┘   └─────────────┘
```

**难度计算**:
```zig
const target_zeros = difficulty / 8;      // 完整的零字节数
const remaining_bits = difficulty % 8;    // 剩余的零位数
```

例如 `difficulty = 20`:
- `target_zeros = 2`: 前2个字节必须是 0x00
- `remaining_bits = 4`: 第3个字节的前4位必须是0

**性能特征**:

| 难度 | 平均尝试次数 | 预期时间（估算）|
|------|-------------|----------------|
| 8 | 256 | <1ms |
| 16 | 65,536 | ~1ms |
| 20 | 1,048,576 | ~10ms |
| 24 | 16,777,216 | ~100ms |
| 32 | 4,294,967,296 | ~10s |

## 区块链接原理

```
创世块 (index=0)           区块1 (index=1)           区块2 (index=2)
┌──────────────────┐      ┌──────────────────┐      ┌──────────────────┐
│ index: 0         │      │ index: 1         │      │ index: 2         │
│ timestamp: T0    │      │ timestamp: T1    │      │ timestamp: T2    │
│ prev_hash: 0x00..│      │ prev_hash: ──────┼──┐   │ prev_hash: ──────┼──┐
│ data: "Genesis"  │   ┌──┼─► hash: 0xAB..   │  │┌──┼─► hash: 0xCD..   │  │
│ hash: 0xAB..  ◄──┼───┘  │ nonce: 12345     │  ││  │ nonce: 67890     │  │
│ nonce: 42        │      └──────────────────┘  ││  └──────────────────┘  │
└──────────────────┘                            │└────────────────────────┘
                                                │
                        每个区块的 prev_hash 指向前一区块的 hash
```

## 哈希的作用

### 1. 数据完整性

任何数据的微小改变都会导致完全不同的哈希值：

```
原始数据: "Hello" → 哈希: 185f8db32271fe25f...
修改数据: "hello" → 哈希: 2cf24dba5fb0a30e2...
                          ↑ 完全不同
```

### 2. 链式依赖

修改历史区块会破坏整个链：

```
篡改区块1的数据
        │
        ▼
区块1的哈希改变
        │
        ▼
区块2的prev_hash不匹配 → 链无效
        │
        ▼
需要重新挖掘区块2、3、4... → 计算上不可行
```

### 3. 工作量证明

哈希的不可预测性使得找到满足条件的nonce需要大量计算：

```
nonce=0: hash=7f83b1657ff1fc53b92dc18148a1d65dfc2d4b1fa3d677284addd200126d9069
nonce=1: hash=4e07408562bedb8b60ce05c1decfe3ad16b72230967de01f640b7e4729b49fce
nonce=2: hash=6b51d431df5d7f141cbececcf79edf3dd861c3b4069f0b11661a3eefacbba918
...
nonce=N: hash=000000xxxx... ← 找到了！前24位是0
```

## 序列化格式

网络传输时的二进制格式（小端序）：

```
偏移    大小      字段
──────────────────────────
0       4        index
4       8        timestamp
12      32       prev_hash
44      4        data.len
48      N        data (N = data.len)
48+N    32       hash
80+N    8        nonce
──────────────────────────
总计: 88 + data.len 字节
```

## 代码示例

### 创建和挖掘区块

```zig
const std = @import("std");
const Block = @import("blockchain.zig").Block;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 创世块的前一哈希全为0
    var prev_hash: [32]u8 = undefined;
    @memset(&prev_hash, 0);

    // 创建区块
    var block = Block.init(
        allocator,
        0,                          // index
        std.time.timestamp(),       // timestamp
        prev_hash,                  // prev_hash
        "Hello, Blockchain!"        // data
    );
    defer block.deinit(allocator);

    // 挖矿 (难度24)
    block.mine(24);

    // 验证哈希
    const calculated = block.calculateHash();
    std.debug.assert(std.mem.eql(u8, &block.hash, &calculated));
}
```

### 验证区块哈希

```zig
fn isValidBlock(block: *const Block, difficulty: u8) bool {
    // 1. 验证哈希计算正确
    const calculated = block.calculateHash();
    if (!std.mem.eql(u8, &block.hash, &calculated)) {
        return false;
    }
    
    // 2. 验证满足难度要求
    const target_zeros = difficulty / 8;
    for (block.hash[0..target_zeros]) |byte| {
        if (byte != 0) return false;
    }
    
    const remaining_bits = difficulty % 8;
    if (remaining_bits > 0) {
        const mask = @as(u8, 0xFF) << @intCast(8 - remaining_bits);
        if ((block.hash[target_zeros] & mask) != 0) return false;
    }
    
    return true;
}
```

## 当前限制

1. **数据类型单一**: 当前 `data` 只是字节切片，没有结构化的交易格式
2. **无签名验证**: 数据没有密码学签名，无法验证来源
3. **固定难度**: 难度值硬编码，没有动态调整
4. **内存分配**: `init` 中使用 `catch unreachable`，分配失败会崩溃

## 后续改进方向

1. **交易结构**: 将 `data` 替换为 `Transaction[]`
2. **Merkle根**: 多笔交易时使用Merkle树计算根哈希
3. **动态难度**: 根据出块时间自动调整
4. **版本号**: 添加区块版本字段支持协议升级
