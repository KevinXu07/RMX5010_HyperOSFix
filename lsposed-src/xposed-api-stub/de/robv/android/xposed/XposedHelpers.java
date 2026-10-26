package de.robv.android.xposed;

import java.lang.reflect.Field;

/** Compile-time stub: LSPosed provides the real implementation at runtime. */
public final class XposedHelpers {
    private XposedHelpers() {}
    public static Class<?> findClass(String className, ClassLoader classLoader) { return null; }
    public static Class<?> findClassIfExists(String className, ClassLoader classLoader) { return null; }
    public static Object findAndHookMethod(Class<?> clazz, String methodName,
            Object... parameterTypesAndCallback) { return null; }
    public static Object findAndHookMethod(String className, ClassLoader classLoader,
            String methodName, Object... parameterTypesAndCallback) { return null; }
    public static Object newInstance(Class<?> clazz, Object... args) { return null; }
    public static Field findField(Class<?> clazz, String fieldName) { return null; }
    public static Object callMethod(Object obj, String methodName, Object... args) { return null; }
    public static Object callStaticMethod(Class<?> clazz, String methodName, Object... args) { return null; }
    public static Object getObjectField(Object obj, String fieldName) { return null; }
    public static void setObjectField(Object obj, String fieldName, Object value) {}
    public static Object getStaticObjectField(Class<?> clazz, String fieldName) { return null; }
    public static void setStaticObjectField(Class<?> clazz, String fieldName, Object value) {}
    public static int getIntField(Object obj, String fieldName) { return 0; }
    public static void setIntField(Object obj, String fieldName, int value) {}
    public static boolean getBooleanField(Object obj, String fieldName) { return false; }
    public static void setBooleanField(Object obj, String fieldName, boolean value) {}
    public static void setFloatField(Object obj, String fieldName, float value) {}
    public static void setStaticBooleanField(Class<?> clazz, String fieldName, boolean value) {}
    public static Object getAdditionalInstanceField(Object obj, String key) { return null; }
    public static Object setAdditionalInstanceField(Object obj, String key, Object value) { return null; }
    public static Object removeAdditionalInstanceField(Object obj, String key) { return null; }
}
