# 区块链演示项目文档

## 文档目录

本项目包含以下技术文档，详细描述了当前实现和未来开发方向。

### 当前实现

| 文档 | 描述 |
|------|------|
| [01-architecture.md](./01-architecture.md) | 系统架构概述、模块职责、数据流、线程模型 |
| [02-block-structure.md](./02-block-structure.md) | 区块数据结构、哈希计算、挖矿方法详解 |
| [03-blockchain-management.md](./03-blockchain-management.md) | 区块链管理、验证、线程安全策略 |
| [04-proof-of-work.md](./04-proof-of-work.md) | 工作量证明原理、难度计算、安全性分析 |
| [05-network-layer.md](./05-network-layer.md) | P2P网络、消息序列化、服务器实现 |

### 后续开发

| 文档 | 描述 |
|------|------|
| [06-future-development.md](./06-future-development.md) | 10个待开发功能的设计方案和实现指南 |

## 快速导航

### 想了解项目整体结构？
→ 阅读 [01-architecture.md](./01-architecture.md)

### 想了解区块如何工作？
→ 阅读 [02-block-structure.md](./02-block-structure.md)

### 想了解挖矿原理？
→ 阅读 [04-proof-of-work.md](./04-proof-of-work.md)

### 想了解网络通信？
→ 阅读 [05-network-layer.md](./05-network-layer.md)

### 想添加新功能？
→ 阅读 [06-future-development.md](./06-future-development.md)

## 项目状态

### 已实现

- ✅ 区块结构（Block）
- ✅ 区块链管理（Blockchain）
- ✅ SHA-256 哈希
- ✅ 工作量证明挖矿
- ✅ P2P网络基础
- ✅ 区块广播
- ✅ 多线程处理

### 待实现

- ⬜ 交易系统
- ⬜ 钱包/密钥对
- ⬜ 区块链同步
- ⬜ UTXO模型
- ⬜ Merkle树
- ⬜ 动态难度调整
- ⬜ 持久化存储
- ⬜ 消息帧协议
- ⬜ 最长链规则
- ⬜ 节点发现

## 技术栈

- **语言**: Zig 0.15.2+
- **依赖**: 仅使用标准库
- **加密**: std.crypto.hash.sha2.Sha256
- **网络**: std.net (TCP)
- **并发**: std.Thread

## 运行项目

```bash
# 构建
zig build

# 运行（默认端口）
zig build run

# 运行（指定端口）
zig build run -- 8000 8001

# 运行测试
zig build test
```

## 文档约定

- 代码示例使用 Zig 语法
- 流程图使用 ASCII 艺术
- 二进制格式使用表格说明
- LE = Little Endian（小端序）
