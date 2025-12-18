# 网络通信详解

## 概述

本项目实现了一个简单的点对点（P2P）网络层，用于节点间的区块同步。网络层包含节点管理、消息序列化和TCP通信功能。

## 架构设计

```
┌─────────────────────────────────────────────────────────────────┐
│                         Node (网络节点)                          │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────────┐  │
│  │  服务器线程  │  │  对等节点列表 │  │      消息广播           │  │
│  │ (accept循环)│  │   (peers)    │  │   (broadcastMessage)   │  │
│  └──────┬──────┘  └─────────────┘  └─────────────────────────┘  │
│         │                                                        │
│         ▼                                                        │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │              连接处理线程 (handleConnection)                  │ │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │ │
│  │  │  读取数据    │->│  反序列化    │->│  处理消息            │  │ │
│  │  └─────────────┘  └─────────────┘  └─────────────────────┘  │ │
│  └─────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

## 数据结构

### MessageType - 消息类型枚举

```zig
pub const MessageType = enum(u8) {
    block,             // 0: 单个区块
    request_blocks,    // 1: 请求区块（未实现）
    response_blocks,   // 2: 区块响应（未实现）
};
```

### Message - 消息联合体

```zig
pub const Message = union(MessageType) {
    block: Block,              // 携带一个区块
    request_blocks: void,      // 无数据
    response_blocks: []Block,  // 区块数组
};
```

**标记联合体特点**:
- 内存中包含标记字段和数据字段
- 可以用 `switch` 安全地处理不同类型
- `@intFromEnum(msg)` 获取类型的整数值

### Peer - 对等节点

```zig
pub const Peer = struct {
    address: std.net.Address,  // 对方地址
    stream: std.net.Stream,    // TCP连接流
};
```

### Node - 网络节点

```zig
pub const Node = struct {
    allocator: std.mem.Allocator,  // 内存分配器
    port: u16,                     // 监听端口
    peers: std.ArrayList(Peer),    // 已连接的对等节点
    mutex: std.Thread.Mutex,       // 保护peers的互斥锁
};
```

## 消息序列化协议

### 二进制格式

所有整数使用小端序（Little Endian）：

```
通用格式:
┌──────────┬─────────────────────────┐
│ 类型 (1B) │ 数据 (可变长度)          │
└──────────┴─────────────────────────┘

block 消息 (类型=0):
┌────┬───────┬───────────┬────────────────┬──────────┬──────────┬────────────┬────────┐
│0x00│index  │timestamp  │prev_hash       │data_len  │data      │hash        │nonce   │
│1B  │4B LE  │8B LE      │32B             │4B LE     │变长      │32B         │8B LE   │
└────┴───────┴───────────┴────────────────┴──────────┴──────────┴────────────┴────────┘

request_blocks 消息 (类型=1):
┌────┐
│0x01│
│1B  │
└────┘

response_blocks 消息 (类型=2):
┌────┬───────────┬─────────────────────────────────────────────────────┐
│0x02│num_blocks │blocks[0]...blocks[n]                                │
│1B  │4B LE      │每个区块格式同上（不含类型字节）                        │
└────┴───────────┴─────────────────────────────────────────────────────┘
```

### serializeMessage - 序列化

```zig
pub fn serializeMessage(allocator: std.mem.Allocator, msg: Message) ![]u8
```

**实现流程**:

```
┌─────────────────┐
│ 创建缓冲区       │
│ ArrayList(u8)   │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ 写入消息类型     │
│ 1字节           │
└────────┬────────┘
         │
         ▼
┌─────────────────────────────────────┐
│ 根据类型写入数据:                     │
│ - block: 写入所有字段                 │
│ - request_blocks: 无数据             │
│ - response_blocks: 写入数量+所有区块  │
└────────┬────────────────────────────┘
         │
         ▼
┌─────────────────┐
│ 返回拥有的切片   │
│ toOwnedSlice()  │
└─────────────────┘
```

**代码片段**:
```zig
var buffer = std.ArrayList(u8).initCapacity(allocator, 0) catch unreachable;
defer buffer.deinit(allocator);
var writer = buffer.writer(allocator);

try writer.writeByte(@intFromEnum(msg));  // 类型字节

switch (msg) {
    .block => |block| {
        try writer.writeInt(u32, block.index, .little);
        try writer.writeInt(i64, block.timestamp, .little);
        try writer.writeAll(&block.prev_hash);
        try writer.writeInt(u32, @intCast(block.data.len), .little);
        try writer.writeAll(block.data);
        try writer.writeAll(&block.hash);
        try writer.writeInt(u64, block.nonce, .little);
    },
    // ...
}

return buffer.toOwnedSlice(allocator);
```

### deserializeMessage - 反序列化

```zig
pub fn deserializeMessage(allocator: std.mem.Allocator, data: []const u8) !Message
```

**实现流程**:

```
┌─────────────────┐
│ 检查数据长度     │
│ < 1 则报错      │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ 读取消息类型     │
│ data[0]        │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ 创建读取流       │
│ fixedBufferStream│
└────────┬────────┘
         │
         ▼
┌─────────────────────────────────────┐
│ 根据类型读取数据:                     │
│ - block: 读取所有字段，构造Block      │
│ - request_blocks: 直接返回           │
│ - response_blocks: 读取数量+所有区块  │
└─────────────────────────────────────┘
```

## 节点管理

### init - 初始化节点

```zig
pub fn init(allocator: std.mem.Allocator, port: u16) Node
```

创建一个新的网络节点，准备监听指定端口。

### deinit - 销毁节点

```zig
pub fn deinit(self: *Node) void
```

关闭所有对等连接，释放资源。

### connectToPeer - 连接对等节点

```zig
pub fn connectToPeer(self: *Node, address: std.net.Address) !void
```

**流程**:
```
┌─────────────────┐
│ 建立TCP连接     │
│ tcpConnectTo... │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ 加锁            │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ 添加到peers列表  │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ 解锁            │
└─────────────────┘
```

### broadcastMessage - 广播消息

```zig
pub fn broadcastMessage(self: *Node, msg: Message) !void
```

将消息序列化后发送给所有已连接的对等节点。

**流程**:
```
┌─────────────────┐
│ 序列化消息       │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ 加锁            │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ 遍历所有peers   │
│ 写入数据        │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ 解锁            │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ 释放序列化数据   │
└─────────────────┘
```

## 服务器实现

### startServer - 启动服务器

```zig
pub fn startServer(self: *Node, blockchain: *Blockchain) !void
```

**流程**:
```
┌─────────────────────────┐
│ 解析监听地址             │
│ 127.0.0.1:port          │
└────────────┬────────────┘
             │
             ▼
┌─────────────────────────┐
│ 创建TCP监听器           │
│ address.listen()        │
└────────────┬────────────┘
             │
             ▼
┌─────────────────────────┐◄────────────────┐
│ 接受新连接              │                  │
│ server.accept()         │                  │
└────────────┬────────────┘                  │
             │                               │
             ▼                               │
┌─────────────────────────┐                  │
│ 为每个连接启动新线程     │                  │
│ spawn(handleConnection) │                  │
└────────────┬────────────┘                  │
             │                               │
             └───────────────────────────────┘
                        循环
```

**代码**:
```zig
pub fn startServer(self: *Node, blockchain: *Blockchain) !void {
    const address = try std.net.Address.parseIp4("127.0.0.1", self.port);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();

    while (true) {
        const conn = try server.accept();
        const thread = try std.Thread.spawn(.{}, handleConnection, .{ self, conn.stream, blockchain });
        thread.detach();  // 分离线程，独立运行
    }
}
```

### handleConnection - 处理连接

```zig
fn handleConnection(self: *Node, stream: std.net.Stream, blockchain: *Blockchain) void
```

**流程**:
```
┌─────────────────────────┐
│ 进入读取循环             │
└────────────┬────────────┘
             │
             ▼
┌─────────────────────────┐◄────────────────┐
│ 读取数据到buffer        │                  │
│ stream.read()           │                  │
└────────────┬────────────┘                  │
             │                               │
        bytes_read                           │
             │                               │
      ┌──────┴──────┐                       │
      │             │                        │
   == 0         > 0                          │
      │             │                        │
      ▼             ▼                        │
┌──────────┐  ┌─────────────────┐           │
│ 连接关闭  │  │ 反序列化消息     │           │
│ 退出循环  │  └────────┬────────┘           │
└──────────┘           │                     │
                       ▼                     │
              ┌─────────────────┐            │
              │ 处理消息        │            │
              │ switch(msg)    │            │
              └────────┬────────┘            │
                       │                     │
                       └─────────────────────┘
```

**区块处理逻辑**:
```zig
.block => |block| {
    blockchain.mutex.lock();
    defer blockchain.mutex.unlock();
    
    // 检查区块索引是否正确（紧接在最后一个区块之后）
    if (block.index == blockchain.blocks.items.len) {
        const prev_block = &blockchain.blocks.items[block.index - 1];
        
        // 验证prev_hash和hash
        if (std.mem.eql(u8, &block.prev_hash, &prev_block.hash) and 
            std.mem.eql(u8, &block.hash, &block.calculateHash())) {
            blockchain.addBlockUnsafe(block) catch {};
        }
    }
},
```

## 通信流程图

### 节点启动和连接

```
节点A (端口8000)                    节点B (端口8001)
      │                                  │
      ├── init(8000)                     ├── init(8001)
      │                                  │
      ├── startServer() ──┐              ├── startServer() ──┐
      │                   │              │                   │
      │              监听8000            │              监听8001
      │                   │              │                   │
      ├── connectToPeer(8001) ────────────>│
      │                   │              │  accept()
      │                   │              │  spawn(handleConnection)
      │                   │              │
      │    TCP连接建立完成               │
      │                                  │
```

### 区块广播

```
节点A                                节点B
  │                                    │
  ├── 挖矿成功，得到新区块               │
  │                                    │
  ├── broadcastMessage({block: newBlock})  │
  │         │                          │
  │         └────── TCP ──────────────>│
  │                                    ├── stream.read()
  │                                    ├── deserializeMessage()
  │                                    ├── 验证区块
  │                                    ├── addBlockUnsafe()
  │                                    │
```

## 线程模型

```
节点进程
    │
    ├── 主线程
    │       │
    │       ├── 初始化
    │       ├── 连接对等节点
    │       └── 等待/控制
    │
    ├── 服务器线程 (startServer)
    │       │
    │       └── accept循环 ──┬──> 连接处理线程1 (handleConnection)
    │                        ├──> 连接处理线程2
    │                        └──> 连接处理线程N
    │
    └── 挖矿线程 (miningLoop)
            │
            └── 挖矿循环
                    ├── getLatestBlock()
                    ├── mine()
                    ├── addBlockUnsafe()
                    └── broadcastMessage()
```

## 当前实现的限制

### 1. 固定缓冲区大小

```zig
var buffer: [1024]u8 = undefined;
const bytes_read = stream.read(&buffer) catch break;
```

**问题**: 超过1024字节的消息会被截断

**改进方案**: 添加消息长度前缀
```
┌──────────┬──────────┬─────────────────────────┐
│ 长度 (4B) │ 类型 (1B) │ 数据 (变长)              │
└──────────┴──────────┴─────────────────────────┘
```

### 2. 没有消息帧边界

当前实现假设每次 `read()` 返回完整消息，但TCP是流协议，可能：
- 一次读取包含多个消息
- 一个消息被分成多次读取

### 3. request_blocks/response_blocks 未实现

```zig
.request_blocks => return Message{ .request_blocks = {} },
.response_blocks => {
    // 反序列化逻辑已实现，但未在handleConnection中使用
},
```

### 4. 无节点发现

当前需要手动指定对等节点地址，没有自动发现机制。

### 5. 无重连机制

连接断开后不会尝试重连。

### 6. 仅支持本地连接

```zig
const address = try std.net.Address.parseIp4("127.0.0.1", self.port);
```

硬编码为 127.0.0.1，不支持跨机器通信。

## 代码示例

### 完整的消息收发流程

```zig
const std = @import("std");
const network = @import("network.zig");
const Block = @import("blockchain.zig").Block;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 创建测试区块
    var prev_hash: [32]u8 = undefined;
    @memset(&prev_hash, 0);
    var block = Block.init(allocator, 0, std.time.timestamp(), prev_hash, "Test");
    block.mine(16);
    defer block.deinit(allocator);

    // 序列化
    const data = try network.serializeMessage(allocator, network.Message{ .block = block });
    defer allocator.free(data);

    std.debug.print("Serialized size: {} bytes\n", .{data.len});

    // 反序列化
    const msg = try network.deserializeMessage(allocator, data);
    switch (msg) {
        .block => |b| {
            std.debug.print("Deserialized block index: {}\n", .{b.index});
        },
        else => {},
    }
}
```

### 手动连接多个节点

```bash
# 终端1: 启动节点A，监听8000，尝试连接8001
zig build run -- 8000 8001

# 终端2: 启动节点B，监听8001，尝试连接8000
zig build run -- 8001 8000

# 节点会互相连接，并共享挖出的区块
```

## 后续改进方向

1. **消息帧协议**: 添加长度前缀，正确处理TCP流
2. **区块链同步**: 实现 request_blocks/response_blocks 逻辑
3. **节点发现**: 添加 DHT 或种子节点机制
4. **重连机制**: 检测断连并自动重连
5. **心跳机制**: 定期发送心跳检测连接状态
6. **加密通信**: 添加 TLS 或自定义加密层
7. **带宽控制**: 限制消息频率和大小
