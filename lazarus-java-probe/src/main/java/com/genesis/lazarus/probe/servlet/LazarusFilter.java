package com.genesis.lazarus.probe.servlet;

import com.genesis.lazarus.probe.Hashing;
import com.genesis.lazarus.probe.LazarusConfig;
import com.genesis.lazarus.probe.LazarusContext;
import com.genesis.lazarus.probe.LazarusProbe;
import com.genesis.lazarus.probe.Masking;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.util.Enumeration;
import java.util.LinkedHashMap;
import java.util.Map;
import javax.servlet.Filter;
import javax.servlet.FilterChain;
import javax.servlet.FilterConfig;
import javax.servlet.ServletException;
import javax.servlet.ServletInputStream;
import javax.servlet.ServletRequest;
import javax.servlet.ServletResponse;
import javax.servlet.http.HttpServletRequest;

public final class LazarusFilter implements Filter {
    @Override
    public void init(FilterConfig filterConfig) {
        LazarusProbe.start();
    }

    @Override
    public void doFilter(ServletRequest request, ServletResponse response, FilterChain chain)
            throws IOException, ServletException {
        if (!LazarusProbe.isEnabled() || !(request instanceof HttpServletRequest)) {
            chain.doFilter(request, response);
            return;
        }

        LazarusConfig config = LazarusProbe.config();
        HttpServletRequest http = (HttpServletRequest) request;
        CachedBodyRequest wrapped = CachedBodyRequest.wrap(http, config.maxFieldBytes);
        LazarusContext.Capture capture = LazarusContext.begin(operationName(http), config);
        try {
            capture.snapshot().context.principal =
                    http.getUserPrincipal() == null ? null : http.getUserPrincipal().getName();
            capture.snapshot().upstream.method = http.getMethod();
            capture.snapshot().upstream.uri = http.getRequestURI();
            capture.snapshot().upstream.headers = headers(http, config.maxFieldBytes);
            capture.snapshot().upstream.body = wrapped.bodyAsString(config.maxFieldBytes);
            capture.snapshot().upstream.raw_body_sha256 = Hashing.sha256Hex(wrapped.body());
            chain.doFilter(wrapped, response);
        } finally {
            LazarusProbe.offer(capture);
            LazarusContext.clear();
        }
    }

    @Override
    public void destroy() {
        LazarusProbe.disable();
    }

    private static String operationName(HttpServletRequest request) {
        return request.getMethod() + " " + request.getRequestURI();
    }

    private static Map<String, String> headers(HttpServletRequest request, int maxFieldBytes) {
        Map<String, String> out = new LinkedHashMap<String, String>();
        Enumeration<String> names = request.getHeaderNames();
        if (names == null) {
            return out;
        }
        while (names.hasMoreElements()) {
            String name = names.nextElement();
            out.put(name, Masking.sanitizeString(name, request.getHeader(name), maxFieldBytes));
        }
        return out;
    }

    private static final class CachedBodyRequest extends javax.servlet.http.HttpServletRequestWrapper {
        private final byte[] body;

        private CachedBodyRequest(HttpServletRequest request, byte[] body) {
            super(request);
            this.body = body;
        }

        static CachedBodyRequest wrap(HttpServletRequest request, int maxBytes) throws IOException {
            ServletInputStream input = request.getInputStream();
            ByteArrayOutputStream out = new ByteArrayOutputStream(Math.min(maxBytes, 8192));
            byte[] buffer = new byte[4096];
            int total = 0;
            int read;
            while ((read = input.read(buffer)) != -1) {
                int remaining = maxBytes - total;
                if (remaining <= 0) {
                    break;
                }
                int len = Math.min(read, remaining);
                out.write(buffer, 0, len);
                total += len;
            }
            return new CachedBodyRequest(request, out.toByteArray());
        }

        byte[] body() {
            return body;
        }

        Object bodyAsString(int maxFieldBytes) {
            return Masking.sanitizeValue("body", new String(body, java.nio.charset.StandardCharsets.UTF_8), maxFieldBytes);
        }

        @Override
        public ServletInputStream getInputStream() {
            final java.io.ByteArrayInputStream in = new java.io.ByteArrayInputStream(body);
            return new ServletInputStream() {
                @Override
                public int read() {
                    return in.read();
                }

                @Override
                public boolean isFinished() {
                    return in.available() == 0;
                }

                @Override
                public boolean isReady() {
                    return true;
                }

                @Override
                public void setReadListener(javax.servlet.ReadListener readListener) {
                    // Synchronous legacy servlet path.
                }
            };
        }

        @Override
        public java.io.BufferedReader getReader() {
            return new java.io.BufferedReader(new java.io.InputStreamReader(
                    new java.io.ByteArrayInputStream(body),
                    java.nio.charset.StandardCharsets.UTF_8));
        }
    }
}
