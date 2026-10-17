package hallmark.solver;

import edu.mit.csail.sdg.alloy4.A4Reporter;
import edu.mit.csail.sdg.alloy4.Err;
import edu.mit.csail.sdg.alloy4.Version;
import edu.mit.csail.sdg.ast.Command;
import edu.mit.csail.sdg.ast.Expr;
import edu.mit.csail.sdg.ast.ExprVar;
import edu.mit.csail.sdg.ast.Sig;
import edu.mit.csail.sdg.parser.CompModule;
import edu.mit.csail.sdg.parser.CompUtil;
import edu.mit.csail.sdg.translator.A4Options;
import edu.mit.csail.sdg.translator.A4Solution;
import edu.mit.csail.sdg.translator.A4Tuple;
import edu.mit.csail.sdg.translator.A4TupleSet;
import edu.mit.csail.sdg.translator.TranslateAlloyToKodkod;
import java.io.BufferedReader;
import java.io.FileDescriptor;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.TreeMap;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.regex.Pattern;
import java.util.stream.Stream;
import kodkod.engine.satlab.SATFactory;

/**
 * Hallmark's solver sidecar: Alloy 6.2 behind line-delimited JSON-RPC 2.0 on
 * stdin and stdout, one request per line, answered in order.
 *
 * <pre>
 * version()                                   -> {protocol, alloy, solver, solvers}
 * load(source, modules)                       -> {model_id, commands}
 * check(model_id, command, scope?, timeout_ms?) -> {verdict, ms, instance_id?, instance?, reason?}
 * eval(model_id, instance_id, expr)           -> {tuples} or {value}
 * unload(model_id)                            -> {}
 * </pre>
 *
 * A verdict is "sat" (an instance, so a check has a counterexample), "unsat"
 * or "unknown" (out of time or memory). Alloy cannot interrupt a running
 * solver, so after an unknown the sidecar answers and then exits with
 * EXIT_ABANDONED; the client starts a new one. It holds nothing but loaded
 * models, so a restart loses nothing the client cannot send again.
 */
public final class Sidecar {
    static final int PROTOCOL = 1;
    static final int EXIT_ABANDONED = 75;

    static final int PARSE_ERROR = -32700;
    static final int INVALID_REQUEST = -32600;
    static final int METHOD_NOT_FOUND = -32601;
    static final int INVALID_PARAMS = -32602;
    static final int INTERNAL_ERROR = -32603;
    static final int ALLOY_ERROR = 1;

    private static final Pattern MODULE_NAME = Pattern.compile("[A-Za-z_][A-Za-z0-9_]*");

    private final PrintStream out;
    private final SATFactory solver;
    private final Map<String, Loaded> models = new HashMap<>();
    private final ExecutorService worker = Executors.newSingleThreadExecutor(runnable -> {
        Thread thread = new Thread(runnable, "hallmark-solver");
        thread.setDaemon(true);
        return thread;
    });
    private int nextModel = 1;
    private int nextInstance = 1;

    private record Loaded(CompModule module, Map<String, A4Solution> instances) {}

    /** A JSON-RPC error answer. */
    static final class RpcError extends RuntimeException {
        private static final long serialVersionUID = 1L;
        final int code;

        RpcError(int code, String message) {
            super(message);
            this.code = code;
        }
    }

    /** An answer after which this process must not keep running. */
    static final class Abandon extends RuntimeException {
        private static final long serialVersionUID = 1L;
        final transient Map<String, Object> result;

        Abandon(Map<String, Object> result) {
            super(String.valueOf(result.get("reason")));
            this.result = result;
        }
    }

    Sidecar(PrintStream out, SATFactory solver) {
        this.out = out;
        this.solver = solver;
    }

    public static void main(String[] args) throws IOException {
        // Kodkod logs every translation step at INFO through slf4j-simple.
        System.setProperty("org.slf4j.simpleLogger.defaultLogLevel", "warn");
        // Only protocol lines go to stdout; anything Alloy or a solver prints
        // goes to stderr, which the client keeps for error messages.
        PrintStream protocol = new PrintStream(new FileOutputStream(FileDescriptor.out), true, StandardCharsets.UTF_8);
        System.setOut(System.err);

        String name = "sat4j";
        for (int i = 0; i < args.length; i++) {
            if (args[i].equals("--solver") && i + 1 < args.length) name = args[++i];
        }
        Optional<SATFactory> solver = SATFactory.find(name);
        if (solver.isEmpty()) {
            System.err.println("hallmark-solver: no such solver " + name + "; available: " + solverIds());
            System.exit(2);
        }

        BufferedReader in = new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8));
        new Sidecar(protocol, solver.get()).serve(in);
        System.exit(0);
    }

    void serve(BufferedReader in) throws IOException {
        String line;
        while ((line = in.readLine()) != null) {
            if (!line.isBlank()) handle(line);
        }
    }

    void handle(String line) {
        Object id = null;
        try {
            Object parsed;
            try {
                parsed = Json.parse(line);
            } catch (IllegalArgumentException e) {
                throw new RpcError(PARSE_ERROR, e.getMessage());
            }
            if (!(parsed instanceof Map<?, ?> request)) throw new RpcError(INVALID_REQUEST, "request is not an object");
            id = request.get("id");
            Object method = request.get("method");
            if (!(method instanceof String)) throw new RpcError(INVALID_REQUEST, "request has no method");
            Object params = request.get("params");
            Map<?, ?> args = params instanceof Map<?, ?> map ? map : Map.of();
            reply(id, dispatch((String) method, args));
        } catch (Abandon e) {
            reply(id, e.result);
            out.flush();
            Runtime.getRuntime().halt(EXIT_ABANDONED);
        } catch (RpcError e) {
            error(id, e.code, e.getMessage());
        } catch (Err e) {
            error(id, ALLOY_ERROR, e.toString().trim());
        } catch (RuntimeException e) {
            error(id, INTERNAL_ERROR, e.toString());
        }
    }

    private Object dispatch(String method, Map<?, ?> params) throws Err {
        return switch (method) {
            case "version" -> version();
            case "load" -> load(params);
            case "check" -> check(params);
            case "eval" -> eval(params);
            case "unload" -> unload(params);
            default -> throw new RpcError(METHOD_NOT_FOUND, "unknown method " + method);
        };
    }

    private Map<String, Object> version() {
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("protocol", PROTOCOL);
        result.put("alloy", Version.version());
        result.put("solver", solver.id());
        result.put("solvers", solverIds());
        return result;
    }

    private static List<String> solverIds() {
        return SATFactory.getSolvers().stream().map(SATFactory::id).toList();
    }

    /**
     * Parses a model. Opened modules come as text and are written next to the
     * model in a scratch directory, as the CLI backend does, so `open catalog`
     * resolves the same way.
     */
    private Map<String, Object> load(Map<?, ?> params) throws Err {
        String source = string(params, "source");
        Object modules = params.get("modules");
        Path dir;
        try {
            dir = Files.createTempDirectory("hallmark-solver");
        } catch (IOException e) {
            throw new RpcError(INTERNAL_ERROR, "cannot create a scratch directory: " + e.getMessage());
        }
        CompModule module;
        try {
            if (modules instanceof Map<?, ?> map) {
                for (Map.Entry<?, ?> entry : map.entrySet()) {
                    String name = String.valueOf(entry.getKey());
                    if (!MODULE_NAME.matcher(name).matches()) {
                        throw new RpcError(INVALID_PARAMS, "bad module name " + name);
                    }
                    Files.writeString(dir.resolve(name + ".als"), String.valueOf(entry.getValue()));
                }
            }
            Path model = dir.resolve("model.als");
            Files.writeString(model, source);
            module = CompUtil.parseEverything_fromFile(A4Reporter.NOP, null, model.toString());
        } catch (IOException e) {
            throw new RpcError(INTERNAL_ERROR, "cannot write the model: " + e.getMessage());
        } finally {
            delete(dir);
        }

        String id = "m" + nextModel++;
        models.put(id, new Loaded(module, new HashMap<>()));
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("model_id", id);
        result.put("commands", module.getAllCommands().stream().map(command -> command.label).toList());
        return result;
    }

    private Map<String, Object> check(Map<?, ?> params) throws Err {
        Loaded loaded = model(params);
        String label = string(params, "command");
        Command command = loaded.module().getAllCommands().stream()
                .filter(candidate -> candidate.label.equals(label))
                .findFirst()
                .orElseThrow(() -> new RpcError(INVALID_PARAMS, "no command " + label));
        Object scope = params.get("scope");
        if (scope instanceof Long overall) command = withScope(command, overall.intValue());
        long timeout = params.get("timeout_ms") instanceof Long ms ? ms : 0;

        A4Options options = new A4Options();
        options.solver = solver;
        Command chosen = command;
        long start = System.nanoTime();
        Future<A4Solution> future = worker.submit(() -> TranslateAlloyToKodkod.execute_commandFromBook(
                A4Reporter.NOP, loaded.module().getAllReachableSigs(), chosen, options));

        A4Solution solution;
        try {
            solution = timeout > 0 ? future.get(timeout, TimeUnit.MILLISECONDS) : future.get();
        } catch (TimeoutException e) {
            throw new Abandon(unknown("timeout", start));
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new Abandon(unknown("interrupted", start));
        } catch (ExecutionException e) {
            Throwable cause = e.getCause();
            if (cause instanceof OutOfMemoryError) throw new Abandon(unknown("out of memory", start));
            if (cause instanceof Err err) throw err;
            throw new RpcError(INTERNAL_ERROR, String.valueOf(cause));
        }

        Map<String, Object> result = new LinkedHashMap<>();
        result.put("verdict", solution.satisfiable() ? "sat" : "unsat");
        result.put("ms", elapsed(start));
        if (solution.satisfiable()) {
            String instance = "i" + nextInstance++;
            loaded.instances().put(instance, solution);
            result.put("instance_id", instance);
            result.put("instance", instance(solution));
        }
        return result;
    }

    /** The same command with a different overall scope; per-signature bounds stay. */
    private static Command withScope(Command c, int overall) {
        return new Command(c.pos, c.nameExpr, c.label, c.check, overall, c.bitwidth, c.maxseq, c.minprefix,
                c.maxprefix, c.expects, c.scope, c.additionalExactScopes, c.commandKeyword, c.formula, c.parent);
    }

    private static Map<String, Object> unknown(String reason, long start) {
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("verdict", "unknown");
        result.put("reason", reason);
        result.put("ms", elapsed(start));
        return result;
    }

    private static long elapsed(long start) {
        return TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - start);
    }

    /**
     * Field and skolem tuples keyed by label, as the A4 XML groups them; the
     * client decodes both through the same Receipt::Instance.
     */
    private static Map<String, Object> instance(A4Solution solution) throws Err {
        Map<String, List<List<String>>> fields = new TreeMap<>();
        for (Sig sig : solution.getAllReachableSigs()) {
            for (Sig.Field field : sig.getFields()) {
                fields.computeIfAbsent(field.label, key -> new ArrayList<>()).addAll(tuples(solution.eval(field)));
            }
        }
        Map<String, List<List<String>>> skolems = new TreeMap<>();
        for (ExprVar skolem : solution.getAllSkolems()) {
            if (solution.eval(skolem) instanceof A4TupleSet set) {
                skolems.computeIfAbsent(skolem.label, key -> new ArrayList<>()).addAll(tuples(set));
            }
        }
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("fields", fields);
        result.put("skolems", skolems);
        return result;
    }

    private static List<List<String>> tuples(A4TupleSet set) {
        List<List<String>> result = new ArrayList<>();
        for (A4Tuple tuple : set) {
            List<String> atoms = new ArrayList<>();
            for (int i = 0; i < tuple.arity(); i++) atoms.add(tuple.atom(i));
            result.add(atoms);
        }
        return result;
    }

    private Map<String, Object> eval(Map<?, ?> params) throws Err {
        Loaded loaded = model(params);
        String id = string(params, "instance_id");
        A4Solution solution = loaded.instances().get(id);
        if (solution == null) throw new RpcError(INVALID_PARAMS, "no instance " + id);
        Expr expr = CompUtil.parseOneExpression_fromString(loaded.module(), string(params, "expr"));
        Object value = solution.eval(expr);
        Map<String, Object> result = new LinkedHashMap<>();
        if (value instanceof A4TupleSet set) {
            result.put("tuples", tuples(set));
        } else {
            result.put("value", value);
        }
        return result;
    }

    private Map<String, Object> unload(Map<?, ?> params) {
        models.remove(string(params, "model_id"));
        return Map.of();
    }

    private Loaded model(Map<?, ?> params) {
        String id = string(params, "model_id");
        Loaded loaded = models.get(id);
        if (loaded == null) throw new RpcError(INVALID_PARAMS, "no model " + id);
        return loaded;
    }

    private static String string(Map<?, ?> params, String key) {
        if (params.get(key) instanceof String value) return value;
        throw new RpcError(INVALID_PARAMS, "missing string parameter " + key);
    }

    private void reply(Object id, Object result) {
        Map<String, Object> response = new LinkedHashMap<>();
        response.put("jsonrpc", "2.0");
        response.put("id", id);
        response.put("result", result);
        out.println(Json.write(response));
    }

    private void error(Object id, int code, String message) {
        Map<String, Object> error = new LinkedHashMap<>();
        error.put("code", code);
        error.put("message", message);
        Map<String, Object> response = new LinkedHashMap<>();
        response.put("jsonrpc", "2.0");
        response.put("id", id);
        response.put("error", error);
        out.println(Json.write(response));
    }

    private static void delete(Path dir) {
        try (Stream<Path> paths = Files.walk(dir)) {
            paths.sorted(Comparator.reverseOrder()).forEach(path -> path.toFile().delete());
        } catch (IOException e) {
            System.err.println("hallmark-solver: could not delete " + dir + ": " + e.getMessage());
        }
    }
}
