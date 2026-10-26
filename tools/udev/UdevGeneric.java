import android.content.ContentValues;
import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;
import android.util.Base64;

import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.FileInputStream;
import java.security.MessageDigest;

/**
 * 通用 acc_udevid 写入器：
 *   account = accounts_ce.db 里 type=com.xiaomi 的当前账号
 *   fid     = /mnt/vendor/persist/fdsd/dc 里的软件凭证 fid
 *   udevid  = "ud:" + base64url(sha1(account + fid))[:16]
 * 只在 extras 里缺失时写入；--force 可强制覆盖（仅用于自测）。
 */
public class UdevGeneric {
    public static void main(String[] args) {
        String dbPath = args.length > 0 ? args[0] : "/data/system_ce/0/accounts_ce.db";
        String dcPath = args.length > 1 ? args[1] : "/mnt/vendor/persist/fdsd/dc";
        boolean force = args.length > 2 && "--force".equals(args[2]);
        SQLiteDatabase db = null;
        try {
            String text = new String(readAll(dcPath), "UTF-8");
            int brace = text.indexOf('{');
            if (brace < 0) {
                System.out.println("UDEVG no-json-in-dc");
                return;
            }
            String fid = new JSONObject(text.substring(brace)).optString("fid", "");
            if (fid.isEmpty()) {
                System.out.println("UDEVG no-fid");
                return;
            }

            db = SQLiteDatabase.openDatabase(dbPath, null, SQLiteDatabase.OPEN_READWRITE);
            Cursor account = db.rawQuery(
                    "select _id,name from accounts where type='com.xiaomi' limit 1", null);
            if (!account.moveToFirst()) {
                account.close();
                System.out.println("UDEVG no-xiaomi-account");
                return;
            }
            long id = account.getLong(0);
            String name = account.getString(1);
            account.close();

            byte[] digest = MessageDigest.getInstance("SHA-1")
                    .digest((name + fid).getBytes("UTF-8"));
            String value = "ud:" + Base64.encodeToString(digest,
                    Base64.URL_SAFE | Base64.NO_WRAP | Base64.NO_PADDING).substring(0, 16);

            Cursor existing = db.rawQuery(
                    "select value from extras where accounts_id=? and key='acc_udevid'",
                    new String[]{String.valueOf(id)});
            boolean present = existing.moveToFirst() && existing.getString(0) != null
                    && !existing.getString(0).isEmpty();
            existing.close();

            if (present && !force) {
                System.out.println("UDEVG exists account=" + mask(name) + " value=" + mask(value));
                return;
            }
            ContentValues cv = new ContentValues();
            cv.put("value", value);
            int updated = db.update("extras", cv, "accounts_id=? and key=?",
                    new String[]{String.valueOf(id), "acc_udevid"});
            if (updated == 0) {
                ContentValues insert = new ContentValues();
                insert.put("accounts_id", id);
                insert.put("key", "acc_udevid");
                insert.put("value", value);
                db.insertOrThrow("extras", null, insert);
            }
            System.out.println("UDEVG " + (present ? "updated" : "inserted")
                    + " account=" + mask(name) + " value=" + mask(value));
        } catch (Throwable t) {
            System.out.println("UDEVG error: " + t);
            t.printStackTrace(System.out);
        } finally {
            if (db != null) {
                db.close();
            }
        }
    }

    private static byte[] readAll(String path) throws Exception {
        try (FileInputStream in = new FileInputStream(path);
             ByteArrayOutputStream out = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[4096];
            int read;
            while ((read = in.read(buffer)) > 0) {
                out.write(buffer, 0, read);
            }
            return out.toByteArray();
        }
    }

    private static String mask(String value) {
        if (value == null || value.length() < 5) {
            return "***";
        }
        return value.substring(0, 4) + "***" + value.substring(value.length() - 1);
    }
}
