const std = @import("std");
const crypto = std.crypto;

/// 钱包 - 管理密钥对和签名
pub const Wallet = struct {
    /// Ed25519 密钥对
    public_key: [32]u8,
    private_key: [64]u8,

    /// 生成新钱包
    pub fn generate() Wallet {
        var seed: [32]u8 = undefined;
        crypto.random.bytes(&seed);
        return fromSeed(seed);
    }

    /// 从种子创建钱包
    pub fn fromSeed(seed: [32]u8) Wallet {
        const key_pair = crypto.sign.Ed25519.KeyPair.create(seed);
        return Wallet{
            .public_key = key_pair.public_key.bytes,
            .private_key = key_pair.secret_key.bytes,
        };
    }

    /// 获取地址（公钥的 SHA-256 哈希）
    pub fn getAddress(self: *const Wallet) [32]u8 {
        return crypto.hash.sha2.Sha256.hash(&self.public_key, .{});
    }

    /// 签名消息
    pub fn sign(self: *const Wallet, message: []const u8) [64]u8 {
        const secret_key = crypto.sign.Ed25519.SecretKey.fromBytes(self.private_key);
        const key_pair = crypto.sign.Ed25519.KeyPair.fromSecretKey(secret_key);
        const sig = key_pair.sign(message, null);
        return sig.toBytes();
    }

    /// 验证签名
    pub fn verify(public_key: [32]u8, message: []const u8, signature: [64]u8) bool {
        const pub_key = crypto.sign.Ed25519.PublicKey.fromBytes(public_key) catch return false;
        const sig = crypto.sign.Ed25519.Signature.fromBytes(signature);
        sig.verify(message, pub_key) catch return false;
        return true;
    }

    /// 将公钥格式化为十六进制字符串（用于显示）
    pub fn publicKeyHex(self: *const Wallet) [64]u8 {
        var hex: [64]u8 = undefined;
        _ = std.fmt.bufPrint(&hex, "{s}", .{std.fmt.fmtSliceHexLower(&self.public_key)}) catch unreachable;
        return hex;
    }

    /// 将地址格式化为十六进制字符串（用于显示）
    pub fn addressHex(self: *const Wallet) [64]u8 {
        const addr = self.getAddress();
        var hex: [64]u8 = undefined;
        _ = std.fmt.bufPrint(&hex, "{s}", .{std.fmt.fmtSliceHexLower(&addr)}) catch unreachable;
        return hex;
    }
};

test "wallet generation and signing" {
    const wallet = Wallet.generate();

    // 签名和验证
    const message = "Hello, Blockchain!";
    const signature = wallet.sign(message);
    try std.testing.expect(Wallet.verify(wallet.public_key, message, signature));

    // 错误的消息应该验证失败
    try std.testing.expect(!Wallet.verify(wallet.public_key, "Wrong message", signature));
}

test "wallet from seed is deterministic" {
    const seed = [_]u8{1} ** 32;
    const wallet1 = Wallet.fromSeed(seed);
    const wallet2 = Wallet.fromSeed(seed);

    try std.testing.expectEqualSlices(u8, &wallet1.public_key, &wallet2.public_key);
    try std.testing.expectEqualSlices(u8, &wallet1.private_key, &wallet2.private_key);
}
