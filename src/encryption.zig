//! PDF Standard Security Handler support.
//!
//! This module implements known-password decryption for the PDF Standard
//! Security Handler. It intentionally does not implement password recovery.

const std = @import("std");
const parser = @import("parser.zig");

const Object = parser.Object;
const ObjRef = parser.ObjRef;

const Md5 = std.crypto.hash.Md5;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Sha384 = std.crypto.hash.sha2.Sha384;
const Sha512 = std.crypto.hash.sha2.Sha512;
const Aes128 = std.crypto.core.aes.Aes128;
const Aes256 = std.crypto.core.aes.Aes256;

const password_padding = [_]u8{
    0x28, 0xbf, 0x4e, 0x5e, 0x4e, 0x75, 0x8a, 0x41,
    0x64, 0x00, 0x4e, 0x56, 0xff, 0xfa, 0x01, 0x08,
    0x2e, 0x2e, 0x00, 0xb6, 0xd0, 0x68, 0x3e, 0x80,
    0x2f, 0x0c, 0xa9, 0xfe, 0x64, 0x53, 0x69, 0x7a,
};

const aes_salt = [_]u8{ 0x73, 0x41, 0x6c, 0x54 };

const DecryptError = EncryptionError || std.mem.Allocator.Error;

pub const EncryptionError = error{
    UnsupportedSecurityHandler,
    UnsupportedCryptFilter,
    UnsupportedRevision,
    UnsupportedVersion,
    MissingEncryptDictionary,
    MissingPasswordEntry,
    MissingFileId,
    InvalidKeyLength,
    InvalidPassword,
    InvalidCiphertext,
    WeakCryptoDisabled,
    PermissionDenied,
    OutOfMemory,
};

pub const AuthType = enum {
    none,
    empty_user,
    user,
    owner,
};

pub const CryptMethod = enum {
    none,
    rc4,
    aesv2,
    aesv3,
};

pub const Permissions = struct {
    raw: i32 = 0,
    print_low_resolution: bool = false,
    modify: bool = false,
    extract: bool = false,
    annotate: bool = false,
    fill_forms: bool = false,
    accessibility: bool = true,
    assemble: bool = false,
    print_high_resolution: bool = false,
};

pub const Info = struct {
    encrypted: bool = false,
    requires_password: bool = false,
    authenticated: bool = false,
    auth_type: AuthType = .none,
    encryption_version: i32 = 0,
    security_revision: i32 = 0,
    key_bits: u16 = 0,
    stream_method: CryptMethod = .none,
    string_method: CryptMethod = .none,
    encrypt_metadata: bool = true,
    weak_crypto: bool = false,
    permissions: Permissions = .{},
};

pub const SecurityHandler = struct {
    encrypt_ref: ?ObjRef,
    v: i32,
    r: i32,
    length_bits: u16,
    key: [32]u8,
    key_len: usize,
    stream_method: CryptMethod,
    string_method: CryptMethod,
    encrypt_metadata: bool,
    permissions: Permissions,
    auth_type: AuthType,
    weak_crypto: bool,

    pub fn info(self: SecurityHandler) Info {
        return .{
            .encrypted = true,
            .requires_password = self.auth_type != .empty_user,
            .authenticated = true,
            .auth_type = self.auth_type,
            .encryption_version = self.v,
            .security_revision = self.r,
            .key_bits = self.length_bits,
            .stream_method = self.stream_method,
            .string_method = self.string_method,
            .encrypt_metadata = self.encrypt_metadata,
            .weak_crypto = self.weak_crypto,
            .permissions = self.permissions,
        };
    }

    pub fn decryptObject(self: *const SecurityHandler, allocator: std.mem.Allocator, ref: ObjRef, object: Object) DecryptError!Object {
        if (self.encrypt_ref) |encrypt_ref| {
            if (encrypt_ref.eql(ref)) return object;
        }
        return self.decryptObjectValue(allocator, ref, object);
    }

    fn decryptObjectValue(self: *const SecurityHandler, allocator: std.mem.Allocator, ref: ObjRef, object: Object) DecryptError!Object {
        return switch (object) {
            .string => |s| .{ .string = try self.decryptBytes(allocator, ref, s, self.string_method) },
            .hex_string => |s| .{ .hex_string = try self.decryptBytes(allocator, ref, s, self.string_method) },
            .array => |items| blk: {
                const out = try allocator.alloc(Object, items.len);
                errdefer allocator.free(out);
                for (items, 0..) |item, index| {
                    out[index] = try self.decryptObjectValue(allocator, ref, item);
                }
                break :blk .{ .array = out };
            },
            .dict => |dict| .{ .dict = try self.decryptDict(allocator, ref, dict) },
            .stream => |stream| blk: {
                const dict = try self.decryptDict(allocator, ref, stream.dict);
                const data = try self.decryptBytes(allocator, ref, stream.data, self.stream_method);
                break :blk .{ .stream = .{ .dict = dict, .data = data } };
            },
            else => object,
        };
    }

    fn decryptDict(self: *const SecurityHandler, allocator: std.mem.Allocator, ref: ObjRef, dict: Object.Dict) DecryptError!Object.Dict {
        const entries = try allocator.alloc(Object.Dict.Entry, dict.entries.len);
        errdefer allocator.free(entries);
        for (dict.entries, 0..) |entry, index| {
            entries[index] = .{
                .key = entry.key,
                .value = try self.decryptObjectValue(allocator, ref, entry.value),
            };
        }
        return .{ .entries = entries };
    }

    pub fn decryptStreamBytes(self: *const SecurityHandler, allocator: std.mem.Allocator, ref: ObjRef, data: []const u8) DecryptError![]u8 {
        return self.decryptBytes(allocator, ref, data, self.stream_method);
    }

    fn decryptBytes(self: *const SecurityHandler, allocator: std.mem.Allocator, ref: ObjRef, data: []const u8, method: CryptMethod) DecryptError![]u8 {
        return switch (method) {
            .none => try allocator.dupe(u8, data),
            .rc4 => blk: {
                var object_key: [16]u8 = undefined;
                const key = self.objectKey(ref, false, &object_key);
                break :blk try rc4Alloc(allocator, key, data);
            },
            .aesv2 => blk: {
                var object_key: [16]u8 = undefined;
                const key = self.objectKey(ref, true, &object_key);
                break :blk try aesCbcDecryptAlloc(allocator, key, data);
            },
            .aesv3 => try aesCbcDecryptAlloc(allocator, self.key[0..self.key_len], data),
        };
    }

    fn objectKey(self: *const SecurityHandler, ref: ObjRef, aes: bool, out: *[16]u8) []const u8 {
        if (self.r >= 5) return self.key[0..self.key_len];

        var seed: [32 + 5 + 4]u8 = undefined;
        @memcpy(seed[0..self.key_len], self.key[0..self.key_len]);
        seed[self.key_len + 0] = @truncate(ref.num);
        seed[self.key_len + 1] = @truncate(ref.num >> 8);
        seed[self.key_len + 2] = @truncate(ref.num >> 16);
        seed[self.key_len + 3] = @truncate(ref.gen);
        seed[self.key_len + 4] = @truncate(ref.gen >> 8);
        var len = self.key_len + 5;
        if (aes) {
            @memcpy(seed[len .. len + 4], &aes_salt);
            len += 4;
        }

        var digest: [Md5.digest_length]u8 = undefined;
        Md5.hash(seed[0..len], &digest, .{});

        const object_key_len = @min(self.key_len + 5, 16);
        @memcpy(out[0..object_key_len], digest[0..object_key_len]);
        return out[0..object_key_len];
    }
};

pub fn parseAndAuthenticate(
    allocator: std.mem.Allocator,
    encrypt_ref: ?ObjRef,
    encrypt_dict: Object.Dict,
    trailer: Object.Dict,
    password: ?[]const u8,
    allow_empty_password: bool,
) EncryptionError!SecurityHandler {
    _ = allocator;
    const filter = encrypt_dict.getName("Filter") orelse return EncryptionError.UnsupportedSecurityHandler;
    if (!std.mem.eql(u8, filter, "Standard")) return EncryptionError.UnsupportedSecurityHandler;

    if (encrypt_dict.get("SubFilter") != null) return EncryptionError.UnsupportedSecurityHandler;

    const v: i32 = @intCast(encrypt_dict.getInt("V") orelse 0);
    const default_r: i64 = if (v <= 1) 2 else 0;
    const r: i32 = @intCast(encrypt_dict.getInt("R") orelse default_r);
    if (!(v == 1 or v == 2 or v == 4 or v == 5)) return EncryptionError.UnsupportedVersion;
    if (!(r == 2 or r == 3 or r == 4 or r == 5 or r == 6)) return EncryptionError.UnsupportedRevision;

    const default_length: i64 = if (v == 5) 256 else 40;
    var length_bits: u16 = if (v == 1) 40 else @intCast(encrypt_dict.getInt("Length") orelse default_length);
    if (length_bits < 40) length_bits *= 8;
    if (v == 5) length_bits = 256;
    if (length_bits % 8 != 0 or length_bits > 256) return EncryptionError.InvalidKeyLength;
    if (r <= 4 and (length_bits < 40 or length_bits > 128)) return EncryptionError.InvalidKeyLength;
    if (r >= 5 and length_bits != 256) return EncryptionError.InvalidKeyLength;

    const o = encrypt_dict.getString("O") orelse return EncryptionError.MissingPasswordEntry;
    const u = encrypt_dict.getString("U") orelse return EncryptionError.MissingPasswordEntry;
    const p_i64 = encrypt_dict.getInt("P") orelse -4;
    const p: i32 = @truncate(p_i64);
    const encrypt_metadata = dictBool(encrypt_dict, "EncryptMetadata") orelse true;
    const file_id = firstFileId(trailer);

    const methods = try parseCryptMethods(encrypt_dict, v, r, length_bits);
    const weak_crypto = length_bits <= 40 or methods.stream == .rc4 or methods.string == .rc4;

    var handler = SecurityHandler{
        .encrypt_ref = encrypt_ref,
        .v = v,
        .r = r,
        .length_bits = length_bits,
        .key = [_]u8{0} ** 32,
        .key_len = length_bits / 8,
        .stream_method = methods.stream,
        .string_method = methods.string,
        .encrypt_metadata = encrypt_metadata,
        .permissions = permissionsFromP(p, r),
        .auth_type = .none,
        .weak_crypto = weak_crypto,
    };

    const supplied_password = password orelse "";
    if (try authenticateInto(&handler, encrypt_dict, o, u, p, file_id, supplied_password)) |auth_type| {
        handler.auth_type = if (supplied_password.len == 0 and auth_type == .user) .empty_user else auth_type;
        return handler;
    }

    if (password == null and allow_empty_password) {
        if (try authenticateInto(&handler, encrypt_dict, o, u, p, file_id, "")) |auth_type| {
            handler.auth_type = if (auth_type == .user) .empty_user else auth_type;
            return handler;
        }
    }

    return EncryptionError.InvalidPassword;
}

fn authenticateInto(
    handler: *SecurityHandler,
    encrypt_dict: Object.Dict,
    o: []const u8,
    u: []const u8,
    p: i32,
    file_id: []const u8,
    password: []const u8,
) EncryptionError!?AuthType {
    if (handler.r <= 4) {
        if (try authenticateUserR2R4(handler, o, u, p, file_id, password)) return .user;
        if (try authenticateOwnerR2R4(handler, o, u, p, file_id, password)) return .owner;
        return null;
    }

    if (u.len < 48 or o.len < 48) return EncryptionError.MissingPasswordEntry;
    const oe = encrypt_dict.getString("OE") orelse return EncryptionError.MissingPasswordEntry;
    const ue = encrypt_dict.getString("UE") orelse return EncryptionError.MissingPasswordEntry;
    if (oe.len < 32 or ue.len < 32) return EncryptionError.MissingPasswordEntry;

    if (try authenticateOwnerR5R6(handler, o[0..48], u[0..48], oe[0..32], password)) return .owner;
    if (try authenticateUserR5R6(handler, u[0..48], ue[0..32], password)) return .user;
    return null;
}

fn authenticateUserR2R4(
    handler: *SecurityHandler,
    o: []const u8,
    u: []const u8,
    p: i32,
    file_id: []const u8,
    password: []const u8,
) !bool {
    computeFileKeyR2R4(handler, o, p, file_id, password);
    if (handler.r == 2) {
        const encrypted_padding = rc4Stack(handler.key[0..handler.key_len], &password_padding);
        return u.len >= 32 and std.mem.eql(u8, encrypted_padding[0..32], u[0..32]);
    }

    const expected = computeUserValueR3R4(handler.key[0..handler.key_len], file_id);
    return u.len >= 16 and std.mem.eql(u8, expected[0..16], u[0..16]);
}

fn authenticateOwnerR2R4(
    handler: *SecurityHandler,
    o: []const u8,
    u: []const u8,
    p: i32,
    file_id: []const u8,
    password: []const u8,
) !bool {
    if (o.len < 32) return false;
    var owner_key = ownerPasswordKey(handler.r, handler.key_len, password);
    var candidate: [32]u8 = undefined;
    @memcpy(candidate[0..32], o[0..32]);

    if (handler.r == 2) {
        rc4InPlace(owner_key[0..handler.key_len], candidate[0..32]);
    } else {
        var round: i32 = 19;
        while (round >= 0) : (round -= 1) {
            var round_key: [16]u8 = undefined;
            for (owner_key[0..handler.key_len], 0..) |byte, index| {
                round_key[index] = byte ^ @as(u8, @intCast(round));
            }
            rc4InPlace(round_key[0..handler.key_len], candidate[0..32]);
        }
    }

    computeFileKeyR2R4(handler, o, p, file_id, candidate[0..32]);
    if (handler.r == 2) {
        const encrypted_padding = rc4Stack(handler.key[0..handler.key_len], &password_padding);
        return u.len >= 32 and std.mem.eql(u8, encrypted_padding[0..32], u[0..32]);
    }
    const expected = computeUserValueR3R4(handler.key[0..handler.key_len], file_id);
    return u.len >= 16 and std.mem.eql(u8, expected[0..16], u[0..16]);
}

fn authenticateUserR5R6(handler: *SecurityHandler, u: []const u8, ue: []const u8, password: []const u8) !bool {
    var validation: [32]u8 = undefined;
    if (handler.r == 5) {
        hashR5(&validation, password, u[32..40], null);
    } else {
        hardenedHashR6(&validation, password, u[32..40], null);
    }
    if (!std.mem.eql(u8, validation[0..32], u[0..32])) return false;

    var key_hash: [32]u8 = undefined;
    if (handler.r == 5) {
        hashR5(&key_hash, password, u[40..48], null);
    } else {
        hardenedHashR6(&key_hash, password, u[40..48], null);
    }
    const decrypted = try aesCbcDecryptNoPadding(key_hash[0..32], ue[0..32]);
    handler.key[0..32].* = decrypted;
    handler.key_len = 32;
    return true;
}

fn authenticateOwnerR5R6(handler: *SecurityHandler, o: []const u8, u: []const u8, oe: []const u8, password: []const u8) !bool {
    var validation: [32]u8 = undefined;
    if (handler.r == 5) {
        hashR5(&validation, password, o[32..40], u[0..48]);
    } else {
        hardenedHashR6(&validation, password, o[32..40], u[0..48]);
    }
    if (!std.mem.eql(u8, validation[0..32], o[0..32])) return false;

    var key_hash: [32]u8 = undefined;
    if (handler.r == 5) {
        hashR5(&key_hash, password, o[40..48], u[0..48]);
    } else {
        hardenedHashR6(&key_hash, password, o[40..48], u[0..48]);
    }
    const decrypted = try aesCbcDecryptNoPadding(key_hash[0..32], oe[0..32]);
    handler.key[0..32].* = decrypted;
    handler.key_len = 32;
    return true;
}

fn computeFileKeyR2R4(handler: *SecurityHandler, o: []const u8, p: i32, file_id: []const u8, password: []const u8) void {
    var padded: [32]u8 = undefined;
    padPassword(&padded, password);

    var h = Md5.init(.{});
    h.update(&padded);
    h.update(o[0..@min(o.len, 32)]);

    var p_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &p_bytes, @bitCast(p), .little);
    h.update(&p_bytes);
    h.update(file_id);
    if (handler.r >= 4 and !handler.encrypt_metadata) {
        h.update(&.{ 0xff, 0xff, 0xff, 0xff });
    }

    var digest: [16]u8 = undefined;
    h.final(&digest);

    const key_len = handler.length_bits / 8;
    if (handler.r >= 3) {
        var i: usize = 0;
        while (i < 50) : (i += 1) {
            Md5.hash(digest[0..key_len], &digest, .{});
        }
    }

    @memcpy(handler.key[0..key_len], digest[0..key_len]);
    handler.key_len = key_len;
}

fn computeUserValueR3R4(file_key: []const u8, file_id: []const u8) [32]u8 {
    var h = Md5.init(.{});
    h.update(&password_padding);
    h.update(file_id);
    var digest: [16]u8 = undefined;
    h.final(&digest);

    var value: [32]u8 = undefined;
    @memcpy(value[0..16], &digest);
    @memset(value[16..32], 0);

    var round_key: [16]u8 = undefined;
    var round: u8 = 0;
    while (round < 20) : (round += 1) {
        for (file_key, 0..) |byte, index| {
            round_key[index] = byte ^ round;
        }
        rc4InPlace(round_key[0..file_key.len], value[0..16]);
    }
    return value;
}

fn ownerPasswordKey(r: i32, key_len: usize, password: []const u8) [16]u8 {
    var padded: [32]u8 = undefined;
    padPassword(&padded, password);
    var digest: [16]u8 = undefined;
    Md5.hash(&padded, &digest, .{});
    if (r >= 3) {
        var i: usize = 0;
        while (i < 50) : (i += 1) {
            Md5.hash(digest[0..key_len], &digest, .{});
        }
    }
    return digest;
}

fn hashR5(out: []u8, password: []const u8, salt: []const u8, owner_key: ?[]const u8) void {
    std.debug.assert(out.len >= 32);
    const pw = password[0..@min(password.len, 127)];
    var h = Sha256.init(.{});
    h.update(pw);
    h.update(salt[0..8]);
    if (owner_key) |key| h.update(key);
    var digest: [32]u8 = undefined;
    h.final(&digest);
    @memcpy(out[0..32], &digest);
}

fn hardenedHashR6(out: *[32]u8, password: []const u8, salt: []const u8, owner_key: ?[]const u8) void {
    const pw = password[0..@min(password.len, 127)];
    var block: [64]u8 = undefined;
    var block_size: usize = 32;
    hashR5(block[0..32], pw, salt, owner_key);

    var data: [(128 + 64 + 48) * 64]u8 = undefined;
    var data_len: usize = 0;
    var iter: usize = 0;
    while (iter < 64 or iter < @as(usize, data[data_len * 64 - 1]) + 32) : (iter += 1) {
        data_len = pw.len + block_size + if (owner_key) |key| key.len else 0;
        var offset: usize = 0;
        var repeat: usize = 0;
        while (repeat < 64) : (repeat += 1) {
            @memcpy(data[offset .. offset + pw.len], pw);
            offset += pw.len;
            @memcpy(data[offset .. offset + block_size], block[0..block_size]);
            offset += block_size;
            if (owner_key) |key| {
                @memcpy(data[offset .. offset + key.len], key);
                offset += key.len;
            }
        }

        var encrypted = data[0 .. data_len * 64];
        aes128CbcCryptInPlace(block[0..16], block[16..32], encrypted, .encrypt);

        var sum: u16 = 0;
        for (encrypted[0..16]) |byte| sum += byte;
        block_size = 32 + (@as(usize, sum % 3) * 16);
        switch (block_size) {
            32 => Sha256.hash(encrypted, block[0..32], .{}),
            48 => Sha384.hash(encrypted, block[0..48], .{}),
            64 => Sha512.hash(encrypted, block[0..64], .{}),
            else => unreachable,
        }
    }
    out.* = block[0..32].*;
}

const CryptMethods = struct {
    stream: CryptMethod,
    string: CryptMethod,
};

fn parseCryptMethods(dict: Object.Dict, v: i32, r: i32, length_bits: u16) EncryptionError!CryptMethods {
    _ = length_bits;
    if (v == 1 or v == 2) return .{ .stream = .rc4, .string = .rc4 };
    if (v == 5) return .{ .stream = .aesv3, .string = .aesv3 };
    if (v != 4) return EncryptionError.UnsupportedVersion;

    const stream_name = dict.getName("StmF") orelse "Identity";
    const string_name = dict.getName("StrF") orelse "Identity";
    const cf = dict.getDict("CF");
    return .{
        .stream = try cryptMethodFromName(cf, stream_name, r),
        .string = try cryptMethodFromName(cf, string_name, r),
    };
}

fn cryptMethodFromName(cf: ?Object.Dict, name: []const u8, r: i32) EncryptionError!CryptMethod {
    if (std.mem.eql(u8, name, "Identity")) return .none;
    if (!std.mem.eql(u8, name, "StdCF")) return EncryptionError.UnsupportedCryptFilter;

    const dict = cf orelse return .rc4;
    const stdcf_obj = dict.get("StdCF") orelse return .rc4;
    const stdcf = switch (stdcf_obj) {
        .dict => |d| d,
        else => return EncryptionError.UnsupportedCryptFilter,
    };
    const cfm = stdcf.getName("CFM") orelse "V2";
    if (std.mem.eql(u8, cfm, "None")) return .none;
    if (std.mem.eql(u8, cfm, "V2")) return .rc4;
    if (std.mem.eql(u8, cfm, "AESV2")) return .aesv2;
    if (std.mem.eql(u8, cfm, "AESV3") and r >= 5) return .aesv3;
    return EncryptionError.UnsupportedCryptFilter;
}

fn firstFileId(trailer: Object.Dict) []const u8 {
    const id_obj = trailer.get("ID") orelse return "";
    const arr = switch (id_obj) {
        .array => |a| a,
        else => return "",
    };
    if (arr.len == 0) return "";
    return switch (arr[0]) {
        .string => |s| s,
        .hex_string => |s| s,
        else => "",
    };
}

fn dictBool(dict: Object.Dict, key: []const u8) ?bool {
    const obj = dict.get(key) orelse return null;
    return switch (obj) {
        .boolean => |b| b,
        else => null,
    };
}

fn padPassword(out: *[32]u8, password: []const u8) void {
    const len = @min(password.len, 32);
    @memcpy(out[0..len], password[0..len]);
    if (len < 32) @memcpy(out[len..32], password_padding[0 .. 32 - len]);
}

fn permissionsFromP(p: i32, r: i32) Permissions {
    const bits: u32 = @bitCast(p);
    return .{
        .raw = p,
        .print_low_resolution = hasPermission(bits, 3),
        .modify = hasPermission(bits, 4),
        .extract = hasPermission(bits, 5),
        .annotate = hasPermission(bits, 6),
        .fill_forms = if (r >= 3) hasPermission(bits, 9) else hasPermission(bits, 6),
        .accessibility = true,
        .assemble = if (r >= 3) hasPermission(bits, 11) else false,
        .print_high_resolution = if (r >= 3) hasPermission(bits, 12) else hasPermission(bits, 3),
    };
}

fn hasPermission(bits: u32, spec_bit: u5) bool {
    return (bits & (@as(u32, 1) << (spec_bit - 1))) != 0;
}

const AesDirection = enum { encrypt, decrypt };

fn aesCbcDecryptAlloc(allocator: std.mem.Allocator, key: []const u8, data: []const u8) ![]u8 {
    if (data.len < 16 or (data.len - 16) % 16 != 0) return EncryptionError.InvalidCiphertext;
    const iv = data[0..16];
    const cipher = data[16..];
    var plain = try allocator.dupe(u8, cipher);
    errdefer allocator.free(plain);
    aesCbcCryptInPlace(key, iv, plain, .decrypt);
    const trim_len = stripPkcs7(plain) catch return EncryptionError.InvalidCiphertext;
    const out = try allocator.dupe(u8, plain[0..trim_len]);
    allocator.free(plain);
    return out;
}

fn aesCbcDecryptNoPadding(key: []const u8, cipher: []const u8) ![32]u8 {
    if (cipher.len != 32) return EncryptionError.InvalidCiphertext;
    var out: [32]u8 = cipher[0..32].*;
    const zero_iv = [_]u8{0} ** 16;
    aesCbcCryptInPlace(key, &zero_iv, out[0..], .decrypt);
    return out;
}

fn aesCbcCryptInPlace(key: []const u8, iv: []const u8, data: []u8, direction: AesDirection) void {
    if (key.len == 16) {
        aes128CbcCryptInPlace(key, iv, data, direction);
    } else {
        aes256CbcCryptInPlace(key, iv, data, direction);
    }
}

fn aes128CbcCryptInPlace(key: []const u8, iv: []const u8, data: []u8, direction: AesDirection) void {
    const typed_key: [16]u8 = key[0..16].*;
    var prev: [16]u8 = iv[0..16].*;
    switch (direction) {
        .encrypt => {
            const ctx = Aes128.initEnc(typed_key);
            var offset: usize = 0;
            while (offset < data.len) : (offset += 16) {
                var block: [16]u8 = undefined;
                @memcpy(&block, data[offset .. offset + 16]);
                xorBlock(&block, &prev);
                ctx.encrypt(&block, &block);
                @memcpy(data[offset .. offset + 16], &block);
                prev = block;
            }
        },
        .decrypt => {
            const ctx = Aes128.initDec(typed_key);
            var offset: usize = 0;
            while (offset < data.len) : (offset += 16) {
                var cipher_block: [16]u8 = undefined;
                @memcpy(&cipher_block, data[offset .. offset + 16]);
                var block = cipher_block;
                ctx.decrypt(&block, &block);
                xorBlock(&block, &prev);
                @memcpy(data[offset .. offset + 16], &block);
                prev = cipher_block;
            }
        },
    }
}

fn aes256CbcCryptInPlace(key: []const u8, iv: []const u8, data: []u8, direction: AesDirection) void {
    const typed_key: [32]u8 = key[0..32].*;
    var prev: [16]u8 = iv[0..16].*;
    switch (direction) {
        .encrypt => {
            const ctx = Aes256.initEnc(typed_key);
            var offset: usize = 0;
            while (offset < data.len) : (offset += 16) {
                var block: [16]u8 = undefined;
                @memcpy(&block, data[offset .. offset + 16]);
                xorBlock(&block, &prev);
                ctx.encrypt(&block, &block);
                @memcpy(data[offset .. offset + 16], &block);
                prev = block;
            }
        },
        .decrypt => {
            const ctx = Aes256.initDec(typed_key);
            var offset: usize = 0;
            while (offset < data.len) : (offset += 16) {
                var cipher_block: [16]u8 = undefined;
                @memcpy(&cipher_block, data[offset .. offset + 16]);
                var block = cipher_block;
                ctx.decrypt(&block, &block);
                xorBlock(&block, &prev);
                @memcpy(data[offset .. offset + 16], &block);
                prev = cipher_block;
            }
        },
    }
}

fn xorBlock(block: *[16]u8, mask: *const [16]u8) void {
    for (block, 0..) |*byte, index| byte.* ^= mask[index];
}

fn stripPkcs7(data: []const u8) !usize {
    if (data.len == 0) return EncryptionError.InvalidCiphertext;
    const pad = data[data.len - 1];
    if (pad == 0 or pad > 16 or pad > data.len) return EncryptionError.InvalidCiphertext;
    for (data[data.len - pad ..]) |byte| {
        if (byte != pad) return EncryptionError.InvalidCiphertext;
    }
    return data.len - pad;
}

fn rc4Alloc(allocator: std.mem.Allocator, key: []const u8, data: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, data);
    errdefer allocator.free(out);
    rc4InPlace(key, out);
    return out;
}

fn rc4Stack(key: []const u8, data: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    @memcpy(out[0..data.len], data);
    rc4InPlace(key, out[0..data.len]);
    return out;
}

fn rc4InPlace(key: []const u8, data: []u8) void {
    var s: [256]u8 = undefined;
    for (&s, 0..) |*v, i| v.* = @intCast(i);

    var j: u8 = 0;
    var i: usize = 0;
    while (i < 256) : (i += 1) {
        j +%= s[i] +% key[i % key.len];
        std.mem.swap(u8, &s[i], &s[j]);
    }

    var x: u8 = 0;
    var y: u8 = 0;
    for (data) |*byte| {
        x +%= 1;
        y +%= s[x];
        std.mem.swap(u8, &s[x], &s[y]);
        const k = s[s[x] +% s[y]];
        byte.* ^= k;
    }
}

test "RC4 test vector" {
    var data = [_]u8{ 0xbb, 0xf3, 0x16, 0xe8, 0xd9, 0x40, 0xaf, 0x0a, 0xd3 };
    rc4InPlace("Key", &data);
    try std.testing.expectEqualStrings("Plaintext", &data);
}

test "AES-CBC decrypt strips PKCS7" {
    const key = [_]u8{0} ** 16;
    const iv = [_]u8{0} ** 16;
    var block = [_]u8{ 0x41, 0x42, 0x43 } ++ [_]u8{13} ** 13;
    aes128CbcCryptInPlace(&key, &iv, &block, .encrypt);
    var encoded: [32]u8 = undefined;
    @memcpy(encoded[0..16], &iv);
    @memcpy(encoded[16..32], &block);
    const out = try aesCbcDecryptAlloc(std.testing.allocator, &key, &encoded);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("ABC", out);
}
