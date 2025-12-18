# 区块链管理详解

## 概述

Blockchain 结构负责管理整个区块链的状态，包括区块的存储、添加、验证和查询。它是区块链系统的核心管理组件。

## 数据结构

### Blockchain 结构定义

```zig
pub const Blockchain = struct {
    allocator: std.mem.Allocator,     // 内存分配器
    blocks: std.ArrayList(Block),      // 区块列表
    mutex: std.Thread.Mutex,           // 线程互斥锁
};
```

### 字段说明

| 字段 | 类型 | 说明 |
|------|------|------|
| allocator | std.mem.Allocator | 用于区块和列表的内存分配 |
| blocks | ArrayList(Block) | 动态数组存储所有区块 |
| mutex | Thread.Mutex | 保护并发访问的互斥锁 |

### 内存结构

```
Blockchain 实例
┌─────────────────────────────────────────┐
│ allocator (指向分配器的指针/接口)         │
├─────────────────────────────────────────┤
│ blocks (ArrayList)                      │
│   ├── items.ptr ──────────────┐         │
│   ├── items.len               │         │
│   └── capacity                │         │
├───────────────────────────────┼─────────┤
│ mutex (Mutex状态)              │         │
└───────────────────────────────┼─────────┘
                                │
                                ▼
                    堆上的 Block 数组
                    ┌─────────────────┐
                    │ Block 0 (创世块) │
                    ├─────────────────┤
                    │ Block 1         │
                    ├─────────────────┤
                    │ Block 2         │
                    ├─────────────────┤
                    │ ...             │
                    └─────────────────┘
```

## 方法详解

### init - 初始化区块链

```zig
pub fn init(allocator: std.mem.Allocator) Blockchain
```

**功能**: 创建空的区块链实例

**实现**:
```zig
return Blockchain{
    .allocator = allocator,
    .blocks = std.ArrayList(Block).initCapacity(allocator, 0) catch unreachable,
    .mutex = std.Thread.Mutex{},
};
```

**特点**:
- 初始容量为0，按需增长
- 使用 `catch unreachable` 处理分配失败（生产环境应改进）

### deinit - 销毁区块链

```zig
pub fn deinit(self: *Blockchain) void
```

**功能**: 释放所有区块和列表内存

**流程**:
```
┌─────────────────────┐
│ 遍历所有区块         │
└─────────┬───────────┘
          │
          ▼
┌─────────────────────┐
│ 调用每个区块的deinit │
│ (释放block.data)    │
└─────────┬───────────┘
          │
          ▼
┌─────────────────────┐
│ 释放ArrayList内存    │
└─────────────────────┘
```

**代码**:
```zig
for (self.blocks.items) |*block| {
    block.deinit(self.allocator);
}
self.blocks.deinit(self.allocator);
```

### createGenesisBlock - 创建创世块

```zig
pub fn createGenesisBlock(self: *Blockchain, data: []const u8) !void
```

**功能**: 创建区块链的第一个区块（创世块）

**创世块特点**:
- index = 0
- prev_hash 全为0（没有前一区块）
- 需要挖矿满足难度要求

**流程**:
```
┌─────────────────────┐
│ 获取当前时间戳       │
└─────────┬───────────┘
          │
          ▼
┌─────────────────────┐
│ 初始化prev_hash为0  │
│ @memset(&prev_hash, 0)│
└─────────┬───────────┘
          │
          ▼
┌─────────────────────┐
│ 创建Block实例       │
│ index=0, data=参数   │
└─────────┬───────────┘
          │
          ▼
┌─────────────────────┐
│ 执行挖矿 mine(24)   │
└─────────┬───────────┘
          │
          ▼
┌─────────────────────┐
│ 添加到blocks列表     │
└─────────────────────┘
```

### addBlock - 添加新区块

```zig
pub fn addBlock(self: *Blockchain, data: []const u8) !void
```

**功能**: 创建新区块并添加到链末尾

**前置条件**: 链中必须至少有一个区块（创世块）

**流程**:
```
┌─────────────────────┐
│ 获取最后一个区块     │
│ prev_block          │
└─────────┬───────────┘
          │
          ▼
┌─────────────────────┐
│ 创建新区块           │
│ index = prev.index+1│
│ prev_hash = prev.hash│
└─────────┬───────────┘
          │
          ▼
┌─────────────────────┐
│ 执行挖矿 mine(24)   │
└─────────┬───────────┘
          │
          ▼
┌─────────────────────┐
│ 添加到blocks列表     │
└─────────────────────┘
```

**注意**: 此方法不加锁，调用者需要确保线程安全。

### addBlockUnsafe - 不加锁添加区块

```zig
pub fn addBlockUnsafe(self: *Blockchain, block: Block) !void
```

**功能**: 直接添加已有区块到链中（不挖矿，不加锁）

**使用场景**:
- 调用者已持有mutex锁
- 区块已经过挖矿和验证
- 从网络接收的区块

**危险**: 名称中的 "Unsafe" 表示：
1. 不进行锁定 → 调用者必须已持有锁
2. 不验证区块 → 调用者必须确保有效性

### getLatestBlock - 获取最新区块

```zig
pub fn getLatestBlock(self: *Blockchain) ?*Block
```

**功能**: 线程安全地获取链上最后一个区块

**返回值**:
- 成功: 返回最后区块的指针
- 空链: 返回 `null`

**线程安全**: 此方法内部加锁

```zig
self.mutex.lock();
defer self.mutex.unlock();
if (self.blocks.items.len == 0) return null;
return &self.blocks.items[self.blocks.items.len - 1];
```

### isValid - 验证链有效性

```zig
pub fn isValid(self: *const Blockchain) bool
```

**功能**: 验证整个区块链的完整性

**验证规则**:
1. 跳过创世块（index=0）
2. 每个区块的 `prev_hash` 必须等于前一区块的 `hash`
3. 每个区块的 `hash` 必须等于重新计算的哈希值

**流程**:
```
┌─────────────────────────────────────────────────────────┐
│                    遍历所有区块                          │
└─────────────────────────────────────────────────────────┘
                          │
          ┌───────────────┴───────────────┐
          │                               │
          ▼                               ▼
   ┌─────────────┐                ┌─────────────────┐
   │ index == 0  │                │ index > 0       │
   │ (创世块)     │                │ (普通区块)       │
   └──────┬──────┘                └────────┬────────┘
          │                                │
          │                    ┌───────────┴───────────┐
          │                    ▼                       ▼
          │           ┌────────────────┐      ┌────────────────┐
          │           │ 检查prev_hash  │      │ 检查hash计算    │
          │           │ == 前块.hash   │      │ == calculateHash│
          │           └───────┬────────┘      └───────┬────────┘
          │                   │                       │
          │                   ▼                       ▼
          │              不匹配?                  不匹配?
          │                   │                       │
          │              return false            return false
          │                   │                       │
          └───────────────────┴───────────────────────┘
                              │
                              ▼
                         return true
```

**代码实现**:
```zig
pub fn isValid(self: *const Blockchain) bool {
    for (self.blocks.items, 0..) |*block, i| {
        if (i == 0) continue;  // 跳过创世块
        
        const prev_block = &self.blocks.items[i - 1];
        
        // 验证链接
        if (!std.mem.eql(u8, &block.prev_hash, &prev_block.hash)) {
            return false;
        }
        
        // 验证哈希
        if (!std.mem.eql(u8, &block.hash, &block.calculateHash())) {
            return false;
        }
    }
    return true;
}
```

## 线程安全模型

### 锁的使用模式

```
场景1: 读取最新区块
┌──────────────────────┐
│ getLatestBlock()     │
│   ├── lock()         │  ← 内部加锁
│   ├── 读取数据        │
│   └── unlock()       │  ← defer 自动解锁
└──────────────────────┘

场景2: 挖矿后添加区块 (main.zig miningLoop)
┌──────────────────────────────────────────────────────┐
│ 1. getLatestBlock()      // 内部有锁                  │
│ 2. 创建新区块              // 无需锁                   │
│ 3. 执行挖矿 mine()         // 无需锁，耗时操作         │
│ 4. mutex.lock()           // 手动加锁                 │
│ 5. 检查index是否仍有效     // 可能有其他线程先添加了    │
│ 6. addBlockUnsafe()       // 不加锁版本               │
│ 7. mutex.unlock()         // defer 自动解锁           │
└──────────────────────────────────────────────────────┘
```

### 为什么需要二次检查

```
线程A (本地挖矿)                    线程B (网络接收)
─────────────────                  ─────────────────
获取最新块 (index=5)                
                                   获取最新块 (index=5)
开始挖矿...                         
                                   收到远程区块 (index=6)
                                   加锁
                                   添加区块
                                   解锁
挖矿完成 (目标index=6)               
加锁
检查: blocks.len=7, 新块index=6
→ 6 != 7，放弃添加 ← 避免重复/冲突
解锁
```

## 区块链状态

```
初始状态 (空链):
┌───────────────┐
│ blocks: []    │
│ len: 0        │
└───────────────┘

创建创世块后:
┌───────────────────────────────────────┐
│ blocks: [Block{index:0, data:"Genesis"}]│
│ len: 1                                 │
└───────────────────────────────────────┘

添加几个区块后:
┌────────────────────────────────────────────────────────┐
│ blocks: [                                              │
│   Block{index:0, prev:0x00.., hash:0xAB..},           │
│   Block{index:1, prev:0xAB.., hash:0xCD..},           │
│   Block{index:2, prev:0xCD.., hash:0xEF..},           │
│ ]                                                      │
│ len: 3                                                 │
└────────────────────────────────────────────────────────┘
```

## 代码示例

### 基本使用

```zig
const std = @import("std");
const Blockchain = @import("blockchain.zig").Blockchain;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 创建区块链
    var bc = Blockchain.init(allocator);
    defer bc.deinit();

    // 创建创世块
    try bc.createGenesisBlock("Genesis Block");

    // 添加新区块
    try bc.addBlock("Transaction: Alice -> Bob: 10");
    try bc.addBlock("Transaction: Bob -> Charlie: 5");

    // 验证链
    if (bc.isValid()) {
        std.debug.print("Blockchain is valid!\n", .{});
    }

    // 获取最新区块
    if (bc.getLatestBlock()) |latest| {
        std.debug.print("Latest block index: {}\n", .{latest.index});
    }
}
```

### 多线程使用

```zig
fn miningThread(bc: *Blockchain) void {
    while (running) {
        // 1. 获取最新块（线程安全）
        const latest = bc.getLatestBlock() orelse continue;
        
        // 2. 在锁外进行耗时的挖矿操作
        var new_block = Block.init(
            bc.allocator,
            latest.index + 1,
            std.time.timestamp(),
            latest.hash,
            "Mining reward"
        );
        new_block.mine(24);  // 耗时操作
        
        // 3. 加锁后再添加
        bc.mutex.lock();
        defer bc.mutex.unlock();
        
        // 4. 检查是否还有效
        if (new_block.index == bc.blocks.items.len) {
            bc.addBlockUnsafe(new_block) catch {};
        } else {
            // 其他线程已添加了区块，放弃本次结果
            new_block.deinit(bc.allocator);
        }
    }
}
```

## 当前限制

1. **无持久化**: 区块链只存在于内存，程序退出即丢失
2. **无分叉处理**: 不支持分叉和最长链选择
3. **验证不完整**: `isValid` 不检查难度证明
4. **无并发读优化**: 读操作也需要获取互斥锁

## 后续改进方向

1. **读写锁**: 使用 `RwLock` 允许多个读取者并发
2. **持久化**: 添加磁盘存储支持
3. **分叉管理**: 实现最长链规则
4. **难度验证**: 在 `isValid` 中检查工作量证明
5. **索引优化**: 添加哈希到区块的索引映射
