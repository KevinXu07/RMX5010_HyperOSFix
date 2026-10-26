import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;

/** Add one app to an LSPosed module scope without the manager UI. */
public final class LspdScope {
    public static void main(String[] args) throws Exception {
        if (args.length < 3) {
            System.out.println("usage: LspdScope <db> <module> <package>");
            return;
        }
        SQLiteDatabase db = SQLiteDatabase.openDatabase(
                args[0], null, SQLiteDatabase.OPEN_READWRITE);
        try {
            db.execSQL("INSERT OR IGNORE INTO scope(module_pkg_name, app_pkg_name, user_id) "
                    + "VALUES(?,?,0)", new Object[]{args[1], args[2]});
            try (Cursor cursor = db.rawQuery(
                    "SELECT app_pkg_name FROM scope WHERE module_pkg_name=? AND user_id=0 "
                            + "ORDER BY app_pkg_name", new String[]{args[1]})) {
                while (cursor.moveToNext()) {
                    System.out.println("scope=" + cursor.getString(0));
                }
            }
        } finally {
            db.close();
        }
    }
}
