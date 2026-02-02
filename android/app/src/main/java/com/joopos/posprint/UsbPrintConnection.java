package com.joopos.posprint;

import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.hardware.usb.UsbConstants;
import android.hardware.usb.UsbDevice;
import android.hardware.usb.UsbDeviceConnection;
import android.hardware.usb.UsbEndpoint;
import android.hardware.usb.UsbInterface;
import android.hardware.usb.UsbManager;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;

import com.joopos.posprint.notification.NotificationUtils;

import java.nio.charset.Charset;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public class UsbPrintConnection {
    public interface Callback {
        void onComplete(boolean success, String message);
    }

    private static final String TAG = "UsbPrintConnection";
    private static final String ACTION_USB_PERMISSION = "com.joopos.posprint.USB_PERMISSION";

    private static final ExecutorService EXEC = Executors.newSingleThreadExecutor();
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private final Context context;

    public UsbPrintConnection(Context ctx) {
        this.context = ctx.getApplicationContext();
    }

    public void printText(String textToPrint, Callback callback) {
        EXEC.execute(() -> {
            boolean success = false;
            String message = "Unknown error";
            UsbManager usbManager = (UsbManager) context.getSystemService(Context.USB_SERVICE);
            if (usbManager == null) {
                post(callback, false, "USB manager not available");
                return;
            }

            UsbDevice target = selectPrinterDevice(usbManager);
            if (target == null) {
                post(callback, false, "No USB printer detected");
                return;
            }

            if (!usbManager.hasPermission(target)) {
                PendingIntent pi = PendingIntent.getBroadcast(context, 0, new Intent(ACTION_USB_PERMISSION), PendingIntent.FLAG_IMMUTABLE);
                usbManager.requestPermission(target, pi);
                long start = System.currentTimeMillis();
                while (!usbManager.hasPermission(target) && System.currentTimeMillis() - start < 1500) {
                    try { Thread.sleep(50); } catch (InterruptedException ignored) {}
                }
            }

            if (!usbManager.hasPermission(target)) {
                post(callback, false, "USB permission denied");
                return;
            }

            UsbInterface intf = findInterface(target);
            UsbEndpoint outEp = findOutEndpoint(intf);
            if (intf == null || outEp == null) {
                post(callback, false, "Printer interface/endpoints not found");
                return;
            }

            UsbDeviceConnection conn = null;
            try {
                conn = usbManager.openDevice(target);
                if (conn == null) {
                    post(callback, false, "Failed to open USB device");
                    return;
                }
                if (!conn.claimInterface(intf, true)) {
                    post(callback, false, "Failed to claim interface");
                    conn.close();
                    return;
                }

                Charset cs = Charset.forName("CP858");
                byte[] data = textToPrint.getBytes(cs);
                byte[] lf = new byte[]{0x0A};
                byte[] feed = new byte[]{0x1B, 0x64, 0x02};
                byte[] cut = new byte[]{0x1D, 0x56, 0x00};

                int r1 = conn.bulkTransfer(outEp, data, data.length, 1000);
                if (r1 < 0) throw new RuntimeException("bulkTransfer data failed");
                int r2 = conn.bulkTransfer(outEp, lf, lf.length, 500);
                int r3 = conn.bulkTransfer(outEp, feed, feed.length, 500);
                int r4 = conn.bulkTransfer(outEp, cut, cut.length, 500);
                if (r2 < 0 || r3 < 0 || r4 < 0) {
                    throw new RuntimeException("bulkTransfer finalize failed");
                }

                success = true;
                message = "USB printed successfully";
            } catch (Exception e) {
                message = "USB printing failed: " + e.getMessage();
                showNotification(message);
                Log.e(TAG, message, e);
            } finally {
                try {
                    if (conn != null) conn.close();
                } catch (Exception ignored) {}
            }

            post(callback, success, message);
        });
    }

    public void printBytes(byte[] data, Callback callback) {
        EXEC.execute(() -> {
            boolean success = false;
            String message = "Unknown error";
            UsbManager usbManager = (UsbManager) context.getSystemService(Context.USB_SERVICE);
            if (usbManager == null) {
                post(callback, false, "USB manager not available");
                return;
            }
            UsbDevice target = selectPrinterDevice(usbManager);
            if (target == null) {
                post(callback, false, "No USB printer detected");
                return;
            }
            if (!usbManager.hasPermission(target)) {
                PendingIntent pi = PendingIntent.getBroadcast(context, 0, new Intent(ACTION_USB_PERMISSION), PendingIntent.FLAG_IMMUTABLE);
                usbManager.requestPermission(target, pi);
                long start = System.currentTimeMillis();
                while (!usbManager.hasPermission(target) && System.currentTimeMillis() - start < 1500) {
                    try { Thread.sleep(50); } catch (InterruptedException ignored) {}
                }
            }
            if (!usbManager.hasPermission(target)) {
                post(callback, false, "USB permission denied");
                return;
            }
            UsbInterface intf = findInterface(target);
            UsbEndpoint outEp = findOutEndpoint(intf);
            if (intf == null || outEp == null) {
                post(callback, false, "Printer interface/endpoints not found");
                return;
            }
            UsbDeviceConnection conn = null;
            try {
                conn = usbManager.openDevice(target);
                if (conn == null) {
                    post(callback, false, "Failed to open USB device");
                    return;
                }
                if (!conn.claimInterface(intf, true)) {
                    post(callback, false, "Failed to claim interface");
                    conn.close();
                    return;
                }
                byte[] init = new byte[]{0x1B, 0x40};
                conn.bulkTransfer(outEp, init, init.length, 500);
                int r = conn.bulkTransfer(outEp, data, data.length, 2000);
                if (r < 0) throw new RuntimeException("bulkTransfer data failed");
                if (!endsWithCut(data)) {
                    byte[] feed = new byte[]{0x1B, 0x64, 0x02};
                    byte[] cut = new byte[]{0x1D, 0x56, 0x00};
                    conn.bulkTransfer(outEp, feed, feed.length, 500);
                    conn.bulkTransfer(outEp, cut, cut.length, 500);
                }
                success = true;
                message = "USB bytes printed";
            } catch (Exception e) {
                message = "USB bytes failed: " + e.getMessage();
                showNotification(message);
                Log.e(TAG, message, e);
            } finally {
                try { if (conn != null) conn.close(); } catch (Exception ignored) {}
            }
            post(callback, success, message);
        });
    }

    private UsbDevice selectPrinterDevice(UsbManager mgr) {
        try {
            HashMap<String, UsbDevice> list = mgr.getDeviceList();
            for (Map.Entry<String, UsbDevice> e : list.entrySet()) {
                UsbDevice d = e.getValue();
                if (isPrinterLike(d)) return d;
            }
        } catch (Exception ignored) {}
        return null;
    }

    private boolean endsWithCut(byte[] data) {
        if (data == null || data.length < 2) return false;
        int start = Math.max(0, data.length - 16);
        for (int i = start; i <= data.length - 2; i++) {
            int b0 = data[i] & 0xFF;
            int b1 = data[i + 1] & 0xFF;
            if (b0 == 0x1D && b1 == 0x56) {
                return true;
            }
        }
        return false;
    }

    private boolean isPrinterLike(UsbDevice d) {
        if (d == null) return false;
        for (int i = 0; i < d.getInterfaceCount(); i++) {
            UsbInterface intf = d.getInterface(i);
            int cls = intf.getInterfaceClass();
            if (cls == UsbConstants.USB_CLASS_PRINTER || cls == UsbConstants.USB_CLASS_VENDOR_SPEC) {
                for (int j = 0; j < intf.getEndpointCount(); j++) {
                    UsbEndpoint ep = intf.getEndpoint(j);
                    if (ep.getType() == UsbConstants.USB_ENDPOINT_XFER_BULK && ep.getDirection() == UsbConstants.USB_DIR_OUT) {
                        return true;
                    }
                }
            }
        }
        return false;
    }

    private UsbInterface findInterface(UsbDevice d) {
        if (d == null) return null;
        for (int i = 0; i < d.getInterfaceCount(); i++) {
            UsbInterface intf = d.getInterface(i);
            int cls = intf.getInterfaceClass();
            if (cls == UsbConstants.USB_CLASS_PRINTER || cls == UsbConstants.USB_CLASS_VENDOR_SPEC) {
                return intf;
            }
        }
        return null;
    }

    private UsbEndpoint findOutEndpoint(UsbInterface intf) {
        if (intf == null) return null;
        for (int j = 0; j < intf.getEndpointCount(); j++) {
            UsbEndpoint ep = intf.getEndpoint(j);
            if (ep.getType() == UsbConstants.USB_ENDPOINT_XFER_BULK && ep.getDirection() == UsbConstants.USB_DIR_OUT) {
                return ep;
            }
        }
        return null;
    }

    private void showNotification(String message) {
        try { NotificationUtils.showPrinterError(context, message); } catch (Exception ignored) {}
    }

    private void post(Callback cb, boolean success, String msg) {
        mainHandler.post(() -> { if (cb != null) cb.onComplete(success, msg); });
    }
}
