package com.genesis.lazarus.probe;

import com.genesis.lazarus.probe.jdbc.LazarusDataSource;
import com.genesis.lazarus.probe.servlet.LazarusFilter;
import java.io.BufferedReader;
import java.io.File;
import java.io.InputStreamReader;
import java.net.HttpURLConnection;
import java.net.URI;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.sql.Connection;
import java.sql.ResultSet;
import java.sql.Statement;
import java.util.EnumSet;
import javax.servlet.DispatcherType;
import javax.servlet.FilterRegistration;
import javax.servlet.ServletException;
import javax.servlet.http.HttpServlet;
import javax.servlet.http.HttpServletRequest;
import javax.servlet.http.HttpServletResponse;
import javax.sql.DataSource;
import org.h2.jdbcx.JdbcDataSource;
import org.junit.After;
import org.junit.Assert;
import org.junit.Before;
import org.junit.Test;
import org.eclipse.jetty.server.Server;
import org.eclipse.jetty.server.ServerConnector;
import org.eclipse.jetty.servlet.ServletContextHandler;
import org.eclipse.jetty.servlet.ServletHolder;

public final class ProbeIntegrationTest {
    private File outputDir;
    private Server server;
    private LazarusDataSource dataSource;

    @Before
    public void setUp() throws Exception {
        outputDir = new File("target/probe-it-snapshots");
        deleteRecursively(outputDir);
        Assert.assertTrue(outputDir.mkdirs());
        System.setProperty("lazarus.probe.enabled", "true");
        System.setProperty("lazarus.probe.output.dir", outputDir.getAbsolutePath());
        System.setProperty("lazarus.probe.queue.capacity", "16");
        System.setProperty("lazarus.probe.max.rows", "500");
        System.setProperty("lazarus.probe.max.field.bytes", "1048576");
        System.setProperty("lazarus.probe.max.snapshot.bytes", "1048576");
        System.setProperty("lazarus.probe.max.dir.bytes", "10485760");

        JdbcDataSource raw = new JdbcDataSource();
        raw.setURL("jdbc:h2:mem:lazarus_probe;DB_CLOSE_DELAY=-1");
        raw.setUser("sa");
        raw.setPassword("");
        initDb(raw);
        dataSource = new LazarusDataSource(raw);

        server = new Server(0);
        ServletContextHandler context = new ServletContextHandler(ServletContextHandler.NO_SESSIONS);
        context.setContextPath("/");
        context.addServlet(new ServletHolder(new QueryServlet(dataSource)), "/account");
        FilterRegistration.Dynamic filter =
                context.getServletContext().addFilter("lazarus", new LazarusFilter());
        filter.addMappingForUrlPatterns(EnumSet.of(DispatcherType.REQUEST), true, "/*");
        server.setHandler(context);
        server.start();
    }

    @After
    public void tearDown() throws Exception {
        LazarusProbe.disable();
        if (server != null) {
            server.stop();
        }
    }

    @Test
    public void capturesServletAndJdbcSnapshotWithMaskedSensitiveColumns() throws Exception {
        Assert.assertEquals("rows=1", getAccountRows(1));
        Assert.assertEquals("rows=0", getAccountRows(42));
        Assert.assertEquals("rows=2", getAccountRows(999));

        String jsonl = waitForJsonl(outputDir, 3);
        Assert.assertTrue(jsonl.contains("\"status\":\"complete\""));
        Assert.assertTrue(jsonl.contains("\"trace_tags\""));
        Assert.assertTrue(jsonl.contains("\"business_method\":\"com.genesis.lazarus.probe.ProbeIntegrationTest$QueryServlet.doGet\""));
        Assert.assertTrue(jsonl.contains("\"uri\":\"/account?id=1\""));
        Assert.assertTrue(jsonl.contains("\"uri\":\"/account?id=42\""));
        Assert.assertTrue(jsonl.contains("\"uri\":\"/account?id=999\""));
        Assert.assertTrue(jsonl.contains("where id = 1"));
        Assert.assertTrue(jsonl.contains("where id = 42"));
        Assert.assertTrue(jsonl.contains("where id >= 999"));
        Assert.assertTrue(jsonl.contains("\"kind\":\"jdbc_read\""));
        Assert.assertTrue(jsonl.contains("\"password\":\"***\""));
        Assert.assertTrue(jsonl.contains("\"card_number\":\"***\""));
        Assert.assertFalse(jsonl.contains("plain-password"));
        Assert.assertFalse(jsonl.contains("4111111111111111"));
        Assert.assertFalse(jsonl.contains("secret-token"));
    }

    private String getAccountRows(int id) throws Exception {
        URL url = new URI("http://127.0.0.1:" + port() + "/account?id=" + id).toURL();
        HttpURLConnection connection = (HttpURLConnection) url.openConnection();
        connection.setRequestProperty("Authorization-Token", "secret-token");
        Assert.assertEquals(200, connection.getResponseCode());
        BufferedReader reader = new BufferedReader(new InputStreamReader(connection.getInputStream(), StandardCharsets.UTF_8));
        return reader.readLine();
    }

    private int port() {
        return ((ServerConnector) server.getConnectors()[0]).getLocalPort();
    }

    private static void initDb(DataSource ds) throws Exception {
        Connection connection = ds.getConnection();
        try {
            Statement statement = connection.createStatement();
            statement.execute("create table accounts (id int primary key, username varchar(64), password varchar(64), card_number varchar(64), note varchar(64))");
            statement.execute("insert into accounts values (1, 'alice', 'plain-password', '4111111111111111', 'hello')");
            statement.execute("insert into accounts values (999, 'bob', 'plain-password', '4222222222222222', 'first')");
            statement.execute("insert into accounts values (1000, 'bob2', 'plain-password', '4333333333333333', 'second')");
            statement.close();
        } finally {
            connection.close();
        }
    }

    private static String waitForJsonl(File dir, int expectedLines) throws Exception {
        long deadline = System.currentTimeMillis() + 3000L;
        while (System.currentTimeMillis() < deadline) {
            File[] files = dir.listFiles();
            if (files != null) {
                for (File file : files) {
                    if (file.getName().endsWith(".jsonl") && file.length() > 0) {
                        String jsonl = new String(Files.readAllBytes(file.toPath()), StandardCharsets.UTF_8);
                        if (lineCount(jsonl) >= expectedLines) {
                            return jsonl;
                        }
                    }
                }
            }
            Thread.sleep(100L);
        }
        throw new AssertionError("snapshot jsonl was not written");
    }

    private static int lineCount(String text) {
        if (text.isEmpty()) {
            return 0;
        }
        return text.split("\\R").length;
    }

    private static void deleteRecursively(File file) throws Exception {
        if (!file.exists()) {
            return;
        }
        if (file.isDirectory()) {
            File[] children = file.listFiles();
            if (children != null) {
                for (File child : children) {
                    deleteRecursively(child);
                }
            }
        }
        if (!file.delete()) {
            throw new ServletException("failed to delete " + file);
        }
    }

    private static final class QueryServlet extends HttpServlet {
        private final DataSource dataSource;

        QueryServlet(DataSource dataSource) {
            this.dataSource = dataSource;
        }

        @Override
        protected void doGet(HttpServletRequest request, HttpServletResponse response)
                throws java.io.IOException {
            try {
                Connection connection = dataSource.getConnection();
                try {
                    int id = parseId(request);
                    Statement statement = connection.createStatement();
                    String predicate = id == 999 ? "id >= 999" : "id = " + id;
                    ResultSet rs = statement.executeQuery("select id, username, password, card_number, note from accounts where " + predicate);
                    int rows = 0;
                    while (rs.next()) {
                        rs.getInt("id");
                        rs.getString("username");
                        rows++;
                    }
                    rs.close();
                    statement.close();
                    response.setStatus(200);
                    response.getWriter().println("rows=" + rows);
                } finally {
                    connection.close();
                }
            } catch (Exception error) {
                response.setStatus(500);
                response.getWriter().println(error.getClass().getName() + ": " + error.getMessage());
            }
        }

        private static int parseId(HttpServletRequest request) {
            String raw = request.getParameter("id");
            if (raw == null || raw.length() == 0) {
                return 1;
            }
            return Integer.parseInt(raw);
        }
    }
}
