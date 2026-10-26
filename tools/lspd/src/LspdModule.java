import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;

/** Register a newly installed LSPosed module and its scope without the manager UI. */
public final class LspdModule {
    public static void main(String[] args) throws Exception {
        if (args.length < 3) {
            System.out.println("usage: LspdModule <db> <module> <apk> [scope...]");
            return;
        }
        String dbPath = args[0];
        String module = args[1];
        String apk = args[2];
        SQLiteDatabase db = SQLiteDatabase.openDatabase(
                dbPath, null, SQLiteDatabase.OPEN_READWRITE);
        try {
            db.execSQL("INSERT OR REPLACE INTO modules(module_pkg_name, apk_path) VALUES(?,?)",
                    new Object[]{module, apk});
            db.execSQL("INSERT OR REPLACE INTO modules_state(module_pkg_name,user_id,enabled,scope_request_blocked) "
                    + "VALUES(?,0,1,0)", new Object[]{module});
            for (int i = 3; i < args.length; i++) {
                db.execSQL("INSERT OR IGNORE INTO scope(module_pkg_name, app_pkg_name, user_id) "
                        + "VALUES(?,?,0)", new Object[]{module, args[i]});
            }
            try (Cursor c = db.rawQuery(
                    "SELECT app_pkg_name FROM scope WHERE module_pkg_name=? AND user_id=0 ORDER BY app_pkg_name",
                    new String[]{module})) {
                while (c.moveToNext()) {
                    System.out.println("scope=" + c.getString(0));
                }
            }
        } finally {
            db.close();
        }
    }
}
