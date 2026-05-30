package com.genesis.lazarus.probe;

import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;

public final class Hashing {
    private Hashing() {}

    public static String sha256Hex(byte[] bytes) {
        return sha256Hex(bytes, bytes.length);
    }

    public static String sha256Hex(byte[] bytes, int len) {
        try {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            digest.update(bytes, 0, Math.min(bytes.length, len));
            byte[] hashed = digest.digest();
            StringBuilder out = new StringBuilder(hashed.length * 2);
            for (byte b : hashed) {
                String hex = Integer.toHexString(b & 0xff);
                if (hex.length() == 1) {
                    out.append('0');
                }
                out.append(hex);
            }
            return out.toString();
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException("SHA-256 unavailable", e);
        }
    }
}
