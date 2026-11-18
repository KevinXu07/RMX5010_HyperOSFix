package android.os;

/** Compile-only stub of the hidden platform class; never put into the dex. */
public final class SystemProperties {
    private SystemProperties() {}

    public static String get(String key) { throw new RuntimeException("stub"); }

    public static String get(String key, String def) { throw new RuntimeException("stub"); }

    public static boolean getBoolean(String key, boolean def) { throw new RuntimeException("stub"); }

    public static int getInt(String key, int def) { throw new RuntimeException("stub"); }

    public static long getLong(String key, long def) { throw new RuntimeException("stub"); }
}
