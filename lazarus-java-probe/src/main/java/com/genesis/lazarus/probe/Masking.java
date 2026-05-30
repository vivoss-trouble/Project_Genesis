package com.genesis.lazarus.probe;

import java.lang.reflect.Array;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

public final class Masking {
    private Masking() {}

    public static Object sanitizeValue(String key, Object value, int maxFieldBytes) {
        if (isSensitiveKey(key)) {
            return "***";
        }
        if (value == null) {
            return null;
        }
        if (value instanceof Number || value instanceof Boolean) {
            return value;
        }
        if (value instanceof CharSequence || value instanceof Character) {
            return truncate(String.valueOf(value), maxFieldBytes);
        }
        if (value instanceof java.sql.Date || value instanceof java.sql.Time || value instanceof java.sql.Timestamp) {
            return String.valueOf(value);
        }
        if (value instanceof byte[]) {
            byte[] bytes = (byte[]) value;
            int len = Math.min(bytes.length, maxFieldBytes);
            return "bytes:" + len + ":sha256:" + Hashing.sha256Hex(bytes, len);
        }
        if (value instanceof Map<?, ?>) {
            Map<String, Object> sanitized = new LinkedHashMap<String, Object>();
            for (Map.Entry<?, ?> entry : ((Map<?, ?>) value).entrySet()) {
                String childKey = String.valueOf(entry.getKey());
                sanitized.put(childKey, sanitizeValue(childKey, entry.getValue(), maxFieldBytes));
            }
            return sanitized;
        }
        if (value instanceof Iterable<?>) {
            List<Object> list = new ArrayList<Object>();
            for (Object item : (Iterable<?>) value) {
                list.add(sanitizeValue(key, item, maxFieldBytes));
            }
            return list;
        }
        if (value.getClass().isArray()) {
            int len = Math.min(Array.getLength(value), 64);
            List<Object> list = new ArrayList<Object>(len);
            for (int i = 0; i < len; i++) {
                list.add(sanitizeValue(key, Array.get(value, i), maxFieldBytes));
            }
            return list;
        }
        return truncate(String.valueOf(value), maxFieldBytes);
    }

    public static String sanitizeString(String key, String value, int maxFieldBytes) {
        Object sanitized = sanitizeValue(key, value, maxFieldBytes);
        return sanitized == null ? null : String.valueOf(sanitized);
    }

    private static String truncate(String value, int maxFieldBytes) {
        if (value == null) {
            return null;
        }
        if (value.length() <= maxFieldBytes) {
            return value;
        }
        return value.substring(0, Math.max(0, maxFieldBytes)) + "...<truncated>";
    }

    private static boolean isSensitiveKey(String key) {
        if (key == null) {
            return false;
        }
        String lower = key.toLowerCase(Locale.ROOT);
        return lower.contains("password")
                || lower.contains("passwd")
                || lower.contains("token")
                || lower.contains("secret")
                || lower.contains("card")
                || lower.contains("ssn")
                || lower.contains("pin");
    }
}
