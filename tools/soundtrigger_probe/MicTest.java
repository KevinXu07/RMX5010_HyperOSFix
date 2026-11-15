import android.media.AudioFormat;
import android.media.AudioRecord;

/** Records a few seconds from the given AudioSource and prints per-second RMS/peak. */
public class MicTest {
    public static void main(String[] a) throws Exception {
        int source = Integer.parseInt(a[0]);
        int secs = Integer.parseInt(a[1]);
        int rate = 16000;
        int min = AudioRecord.getMinBufferSize(rate, AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT);
        AudioRecord r = new AudioRecord(source, rate, AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT, Math.max(min, rate * 2));
        System.out.println("state=" + r.getState() + " source=" + source);
        r.startRecording();
        short[] buf = new short[rate];
        for (int s = 0; s < secs; s++) {
            int n = 0;
            while (n < buf.length) {
                int k = r.read(buf, n, buf.length - n);
                if (k <= 0) break;
                n += k;
            }
            long sum = 0;
            int peak = 0;
            for (int i = 0; i < n; i++) {
                sum += (long) buf[i] * buf[i];
                peak = Math.max(peak, Math.abs(buf[i]));
            }
            System.out.println("sec " + s + " n=" + n + " rms=" + (int) Math.sqrt(sum / Math.max(1, n))
                    + " peak=" + peak);
        }
        r.stop();
        r.release();
        System.exit(0);
    }
}
