package hallmark.solver;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * The JSON subset the protocol needs, so the sidecar depends on nothing but
 * Alloy. Objects parse to LinkedHashMap, arrays to ArrayList, integers to
 * Long, other numbers to Double.
 */
final class Json {
    private final String text;
    private int at;

    private Json(String text) {
        this.text = text;
    }

    static Object parse(String text) {
        Json parser = new Json(text);
        parser.space();
        Object value = parser.value();
        parser.space();
        if (parser.at != text.length()) throw parser.error("trailing characters");
        return value;
    }

    static String write(Object value) {
        StringBuilder out = new StringBuilder();
        write(out, value);
        return out.toString();
    }

    private Object value() {
        if (at >= text.length()) throw error("unexpected end of input");
        char c = text.charAt(at);
        switch (c) {
            case '{': return object();
            case '[': return array();
            case '"': return string();
            case 't': return literal("true", Boolean.TRUE);
            case 'f': return literal("false", Boolean.FALSE);
            case 'n': return literal("null", null);
            default:
                if (c == '-' || (c >= '0' && c <= '9')) return number();
                throw error("unexpected character '" + c + "'");
        }
    }

    private Map<String, Object> object() {
        Map<String, Object> result = new LinkedHashMap<>();
        at++;
        space();
        if (peek('}')) return result;
        while (true) {
            space();
            if (at >= text.length() || text.charAt(at) != '"') throw error("expected a string key");
            String key = string();
            space();
            expect(':');
            space();
            result.put(key, value());
            space();
            if (peek('}')) return result;
            expect(',');
        }
    }

    private List<Object> array() {
        List<Object> result = new ArrayList<>();
        at++;
        space();
        if (peek(']')) return result;
        while (true) {
            space();
            result.add(value());
            space();
            if (peek(']')) return result;
            expect(',');
        }
    }

    private String string() {
        StringBuilder out = new StringBuilder();
        at++;
        while (at < text.length()) {
            char c = text.charAt(at++);
            if (c == '"') return out.toString();
            if (c != '\\') {
                out.append(c);
                continue;
            }
            if (at >= text.length()) break;
            char escape = text.charAt(at++);
            switch (escape) {
                case 'n': out.append('\n'); break;
                case 't': out.append('\t'); break;
                case 'r': out.append('\r'); break;
                case 'b': out.append('\b'); break;
                case 'f': out.append('\f'); break;
                case 'u':
                    if (at + 4 > text.length()) throw error("short unicode escape");
                    out.append((char) Integer.parseInt(text.substring(at, at + 4), 16));
                    at += 4;
                    break;
                default: out.append(escape);
            }
        }
        throw error("unterminated string");
    }

    private Object number() {
        int start = at;
        if (text.charAt(at) == '-') at++;
        boolean integral = true;
        while (at < text.length()) {
            char c = text.charAt(at);
            if (c >= '0' && c <= '9') {
                at++;
            } else if (c == '.' || c == 'e' || c == 'E' || c == '+' || c == '-') {
                integral = false;
                at++;
            } else {
                break;
            }
        }
        String digits = text.substring(start, at);
        try {
            return integral ? (Object) Long.valueOf(digits) : (Object) Double.valueOf(digits);
        } catch (NumberFormatException e) {
            throw error("bad number " + digits);
        }
    }

    private Object literal(String word, Object value) {
        if (!text.startsWith(word, at)) throw error("unexpected token");
        at += word.length();
        return value;
    }

    private boolean peek(char c) {
        if (at < text.length() && text.charAt(at) == c) {
            at++;
            return true;
        }
        return false;
    }

    private void expect(char c) {
        if (!peek(c)) throw error("expected '" + c + "'");
    }

    private void space() {
        while (at < text.length() && Character.isWhitespace(text.charAt(at))) at++;
    }

    private IllegalArgumentException error(String message) {
        return new IllegalArgumentException("JSON parse error at " + at + ": " + message);
    }

    private static void write(StringBuilder out, Object value) {
        if (value == null) {
            out.append("null");
        } else if (value instanceof String s) {
            quote(out, s);
        } else if (value instanceof Boolean || value instanceof Number) {
            out.append(value);
        } else if (value instanceof Map<?, ?> map) {
            out.append('{');
            boolean first = true;
            for (Map.Entry<?, ?> entry : map.entrySet()) {
                if (!first) out.append(',');
                first = false;
                quote(out, String.valueOf(entry.getKey()));
                out.append(':');
                write(out, entry.getValue());
            }
            out.append('}');
        } else if (value instanceof Iterable<?> list) {
            out.append('[');
            boolean first = true;
            for (Object item : list) {
                if (!first) out.append(',');
                first = false;
                write(out, item);
            }
            out.append(']');
        } else {
            quote(out, value.toString());
        }
    }

    private static void quote(StringBuilder out, String s) {
        out.append('"');
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            switch (c) {
                case '"': out.append("\\\""); break;
                case '\\': out.append("\\\\"); break;
                case '\n': out.append("\\n"); break;
                case '\r': out.append("\\r"); break;
                case '\t': out.append("\\t"); break;
                default:
                    if (c < 0x20) {
                        out.append(String.format("\\u%04x", (int) c));
                    } else {
                        out.append(c);
                    }
            }
        }
        out.append('"');
    }
}
