package com.genesis.lazarus.probe.jdbc;

import com.genesis.lazarus.probe.LazarusContext;
import com.genesis.lazarus.probe.Masking;
import com.genesis.lazarus.probe.model.StateSnapshot;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.InvocationHandler;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.ResultSetMetaData;
import java.sql.Statement;
import java.sql.Types;
import java.util.LinkedHashMap;
import java.util.Map;

public final class JdbcProxyFactory {
    private JdbcProxyFactory() {}

    public static Connection wrapConnection(Connection connection) {
        return (Connection) Proxy.newProxyInstance(
                connection.getClass().getClassLoader(),
                new Class<?>[]{Connection.class},
                new ConnectionHandler(connection));
    }

    private static final class ConnectionHandler implements InvocationHandler {
        private final Connection delegate;

        ConnectionHandler(Connection delegate) {
            this.delegate = delegate;
        }

        @Override
        public Object invoke(Object proxy, Method method, Object[] args) throws Throwable {
            String name = method.getName();
            Object result = invokeDelegate(method, delegate, args);
            if ("createStatement".equals(name) && result instanceof Statement) {
                return wrapStatement((Statement) result, null);
            }
            if ("prepareStatement".equals(name) && result instanceof PreparedStatement) {
                String sql = args != null && args.length > 0 ? String.valueOf(args[0]) : null;
                return wrapPreparedStatement((PreparedStatement) result, sql);
            }
            return result;
        }
    }

    private static Statement wrapStatement(Statement statement, String sql) {
        return (Statement) Proxy.newProxyInstance(
                statement.getClass().getClassLoader(),
                new Class<?>[]{Statement.class},
                new StatementHandler(statement, sql));
    }

    private static PreparedStatement wrapPreparedStatement(PreparedStatement statement, String sql) {
        return (PreparedStatement) Proxy.newProxyInstance(
                statement.getClass().getClassLoader(),
                new Class<?>[]{PreparedStatement.class},
                new StatementHandler(statement, sql));
    }

    private static final class StatementHandler implements InvocationHandler {
        private final Statement delegate;
        private final String preparedSql;

        StatementHandler(Statement delegate, String preparedSql) {
            this.delegate = delegate;
            this.preparedSql = preparedSql;
        }

        @Override
        public Object invoke(Object proxy, Method method, Object[] args) throws Throwable {
            String name = method.getName();
            Object result = invokeDelegate(method, delegate, args);
            String sql = sqlFrom(name, args, preparedSql);
            if (result instanceof ResultSet && isRead(name, sql)) {
                return wrapResultSet((ResultSet) result, sql);
            }
            if (isWrite(name, sql)) {
                recordMutation(sql, name);
            }
            return result;
        }

        private static String sqlFrom(String methodName, Object[] args, String preparedSql) {
            if (preparedSql != null) {
                return preparedSql;
            }
            if (args != null && args.length > 0 && args[0] instanceof String) {
                return String.valueOf(args[0]);
            }
            return methodName;
        }
    }

    private static ResultSet wrapResultSet(ResultSet resultSet, String sql) {
        return (ResultSet) Proxy.newProxyInstance(
                resultSet.getClass().getClassLoader(),
                new Class<?>[]{ResultSet.class},
                new ResultSetHandler(resultSet, sql));
    }

    private static final class ResultSetHandler implements InvocationHandler {
        private final ResultSet delegate;
        private final String sql;
        private final StateSnapshot.DownstreamDependency dependency;
        private boolean truncated;

        ResultSetHandler(ResultSet delegate, String sql) {
            this.delegate = delegate;
            this.sql = sql;
            LazarusContext.Capture capture = LazarusContext.current();
            if (capture == null) {
                this.dependency = null;
            } else {
                StateSnapshot.DownstreamDependency dep = new StateSnapshot.DownstreamDependency();
                dep.dependency_id = capture.nextDependencyId();
                dep.kind = "jdbc_read";
                dep.target = "jdbc";
                dep.query_or_request = sql;
                dep.deterministic = true;
                capture.snapshot().downstream_dependencies.add(dep);
                this.dependency = dep;
            }
        }

        @Override
        public Object invoke(Object proxy, Method method, Object[] args) throws Throwable {
            Object result = invokeDelegate(method, delegate, args);
            if ("next".equals(method.getName()) && Boolean.TRUE.equals(result)) {
                captureCurrentRow();
            }
            return result;
        }

        private void captureCurrentRow() {
            LazarusContext.Capture capture = LazarusContext.current();
            if (capture == null || dependency == null || truncated) {
                return;
            }
            if (dependency.rows.size() >= capture.config().maxRows) {
                capture.markTruncatedInvalid();
                truncated = true;
                return;
            }
            try {
                ResultSetMetaData meta = delegate.getMetaData();
                int columns = meta.getColumnCount();
                Map<String, Object> row = new LinkedHashMap<String, Object>();
                for (int index = 1; index <= columns; index++) {
                    String name = meta.getColumnLabel(index);
                    if (name == null || name.length() == 0) {
                        name = meta.getColumnName(index);
                    }
                    name = normalizeColumnName(name);
                    int type = meta.getColumnType(index);
                    Object value = isLob(type) ? "<lob:truncated>" : delegate.getObject(index);
                    row.put(name, Masking.sanitizeValue(name, value, capture.config().maxFieldBytes));
                }
                dependency.rows.add(row);
            } catch (Throwable ignored) {
                capture.markTruncatedInvalid();
                truncated = true;
            }
        }
    }

    private static String normalizeColumnName(String name) {
        return name == null ? "" : name.toLowerCase(java.util.Locale.ROOT);
    }

    private static boolean isRead(String methodName, String sql) {
        return methodName.toLowerCase(java.util.Locale.ROOT).contains("query")
                || (sql != null && sql.trim().toLowerCase(java.util.Locale.ROOT).startsWith("select"));
    }

    private static boolean isWrite(String methodName, String sql) {
        String lower = sql == null ? "" : sql.trim().toLowerCase(java.util.Locale.ROOT);
        return methodName.toLowerCase(java.util.Locale.ROOT).contains("update")
                || lower.startsWith("update")
                || lower.startsWith("insert")
                || lower.startsWith("delete")
                || lower.startsWith("merge");
    }

    private static boolean isLob(int type) {
        return type == Types.BLOB
                || type == Types.CLOB
                || type == Types.NCLOB
                || type == Types.LONGVARBINARY
                || type == Types.LONGVARCHAR
                || type == Types.LONGNVARCHAR;
    }

    private static void recordMutation(String sql, String methodName) {
        LazarusContext.Capture capture = LazarusContext.current();
        if (capture == null) {
            return;
        }
        StateSnapshot.MutationIntent intent = new StateSnapshot.MutationIntent();
        intent.intent_id = capture.nextMutationId();
        intent.kind = mutationKind(sql);
        intent.target = "jdbc";
        intent.statement_or_request = sql;
        intent.params = methodName;
        capture.snapshot().mutation_intents.add(intent);
    }

    private static String mutationKind(String sql) {
        String lower = sql == null ? "" : sql.trim().toLowerCase(java.util.Locale.ROOT);
        if (lower.startsWith("insert")) {
            return "db_insert";
        }
        if (lower.startsWith("delete")) {
            return "db_delete";
        }
        return "db_update";
    }

    private static Object invokeDelegate(Method method, Object target, Object[] args) throws Throwable {
        try {
            return method.invoke(target, args);
        } catch (InvocationTargetException error) {
            throw error.getCause();
        }
    }
}
