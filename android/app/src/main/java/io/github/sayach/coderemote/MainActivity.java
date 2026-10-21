package io.github.sayach.coderemote;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.SharedPreferences;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Bundle;
import android.text.InputType;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowManager;
import android.view.inputmethod.EditorInfo;
import android.webkit.WebChromeClient;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Button;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import androidx.core.view.WindowCompat;
import androidx.core.view.WindowInsetsCompat;
import androidx.core.view.WindowInsetsControllerCompat;

import java.util.ArrayList;
import java.util.List;

public class MainActivity extends Activity {

    private static final String PREFS = "coderemote";
    private static final String KEY_URLS = "urls";
    private static final String KEY_LAST = "last";
    private static final int MAX_HISTORY = 6;

    // 配色(对齐 VS Code 深色)
    private static final int C_BG      = 0xFF0F1419;
    private static final int C_PANEL   = 0xFF161B22;
    private static final int C_BORDER  = 0xFF30363D;
    private static final int C_TEXT    = 0xFFE6EDF3;
    private static final int C_MUTED   = 0xFF8B949E;
    private static final int C_ACCENT  = 0xFF58A6FF;
    private static final int C_GREEN   = 0xFF2EA043;

    private SharedPreferences prefs;

    private FrameLayout root;
    private LinearLayout inputScreen;
    private EditText urlInput;
    private LinearLayout historyBox;
    private WebView webView;
    private ProgressBar progress;
    private boolean connected = false;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        prefs = getSharedPreferences(PREFS, Context.MODE_PRIVATE);

        // 便于 adb 调试(仅调试用途,生产可关闭)
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.KITKAT) {
            WebView.setWebContentsDebuggingEnabled(true);
        }

        root = new FrameLayout(this);
        root.setBackgroundColor(C_BG);
        setContentView(root);

        buildInputScreen();
        showInput();

        // 首次进入:若剪贴板里有可用链接,自动填上
        if (getSavedUrls().isEmpty()) {
            String clip = readClipboard();
            if (clip != null && looksLikeUrl(clip)) {
                urlInput.setText(clip);
            }
        } else {
            String last = prefs.getString(KEY_LAST, "");
            if (last != null && !last.isEmpty()) {
                urlInput.setText(last);
            }
        }
    }

    // =========================================================
    //  输入界面
    // =========================================================
    private int dp(int v) {
        return (int) TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, getResources().getDisplayMetrics());
    }

    private GradientDrawable rounded(int fill, int stroke) {
        GradientDrawable d = new GradientDrawable();
        d.setColor(fill);
        d.setCornerRadius(dp(10));
        if (stroke != 0) d.setStroke(dp(1), stroke);
        return d;
    }

    private void buildInputScreen() {
        ScrollView scroll = new ScrollView(this);
        scroll.setFillViewport(true);

        LinearLayout col = new LinearLayout(this);
        col.setOrientation(LinearLayout.VERTICAL);
        col.setPadding(dp(20), dp(28), dp(20), dp(20));
        scroll.addView(col, new ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        TextView title = new TextView(this);
        title.setText("CodeRemote");
        title.setTextColor(C_TEXT);
        title.setTextSize(TypedValue.COMPLEX_UNIT_SP, 26);
        title.setTypeface(Typeface.DEFAULT_BOLD);
        col.addView(title);

        TextView sub = new TextView(this);
        sub.setText("输入链接后进入全屏编辑");
        sub.setTextColor(C_MUTED);
        sub.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13);
        LinearLayout.LayoutParams subLp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        subLp.topMargin = dp(4);
        subLp.bottomMargin = dp(20);
        col.addView(sub, subLp);

        urlInput = new EditText(this);
        urlInput.setHint("例如  http://[240c:...]:8092/?k=令牌");
        urlInput.setHintTextColor(C_MUTED);
        urlInput.setTextColor(C_TEXT);
        urlInput.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14);
        urlInput.setTypeface(Typeface.MONOSPACE);
        urlInput.setBackground(rounded(C_PANEL, C_BORDER));
        urlInput.setPadding(dp(14), dp(12), dp(14), dp(12));
        urlInput.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI);
        urlInput.setSingleLine(false);
        urlInput.setMaxLines(4);
        urlInput.setSelectAllOnFocus(false);
        col.addView(urlInput, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        // 按钮行
        LinearLayout btnRow = new LinearLayout(this);
        btnRow.setOrientation(LinearLayout.HORIZONTAL);
        LinearLayout.LayoutParams rowLp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        rowLp.topMargin = dp(14);
        col.addView(btnRow, rowLp);

        Button connect = makeButton("连接", C_ACCENT, 0xFF0D1117);
        connect.setOnClickListener(v -> doConnect());
        LinearLayout.LayoutParams lp1 = new LinearLayout.LayoutParams(0, dp(48), 1f);
        lp1.rightMargin = dp(10);
        btnRow.addView(connect, lp1);

        Button paste = makeButton("粘贴", C_PANEL, C_TEXT);
        paste.setOnClickListener(v -> {
            String clip = readClipboard();
            if (clip != null && !clip.isEmpty()) {
                urlInput.setText(clip.trim());
                urlInput.setSelection(urlInput.getText().length());
                Toast.makeText(this, "已粘贴", Toast.LENGTH_SHORT).show();
            } else {
                Toast.makeText(this, "剪贴板为空", Toast.LENGTH_SHORT).show();
            }
        });
        btnRow.addView(paste, new LinearLayout.LayoutParams(dp(96), dp(48)));

        // 历史
        TextView histTitle = new TextView(this);
        histTitle.setText("最近使用");
        histTitle.setTextColor(C_MUTED);
        histTitle.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
        LinearLayout.LayoutParams htLp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        htLp.topMargin = dp(26);
        htLp.bottomMargin = dp(8);
        col.addView(histTitle, htLp);

        historyBox = new LinearLayout(this);
        historyBox.setOrientation(LinearLayout.VERTICAL);
        col.addView(historyBox, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        TextView tip = new TextView(this);
        tip.setText("提示\n· 进入后全屏沉浸,从边缘滑动可临时呼出状态栏\n· 返回键:先退网页,到根目录再按一次可选择退出或换链接\n· 支持外接键盘,按键直接作用于网页");
        tip.setTextColor(C_MUTED);
        tip.setTextSize(TypedValue.COMPLEX_UNIT_SP, 11);
        tip.setLineSpacing(dp(4), 1f);
        LinearLayout.LayoutParams tipLp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        tipLp.topMargin = dp(24);
        col.addView(tip, tipLp);

        inputScreen = col;
        root.addView(scroll, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
    }

    private Button makeButton(String text, int bg, int fg) {
        Button b = new Button(this);
        b.setText(text);
        b.setAllCaps(false);
        b.setTextColor(fg);
        b.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15);
        b.setBackground(rounded(bg, bg == C_PANEL ? C_BORDER : 0));
        b.setStateListAnimator(null);
        return b;
    }

    private void refreshHistory() {
        if (historyBox == null) return;
        historyBox.removeAllViews();
        List<String> urls = getSavedUrls();
        if (urls.isEmpty()) {
            TextView empty = new TextView(this);
            empty.setText("(暂无记录)");
            empty.setTextColor(C_MUTED);
            empty.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
            historyBox.addView(empty);
            return;
        }
        for (String u : urls) {
            TextView row = new TextView(this);
            row.setText(u);
            row.setTextColor(C_ACCENT);
            row.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
            row.setTypeface(Typeface.MONOSPACE);
            row.setSingleLine(true);
            row.setEllipsize(android.text.TextUtils.TruncateAt.MIDDLE);
            row.setBackground(rounded(C_PANEL, C_BORDER));
            row.setPadding(dp(12), dp(12), dp(12), dp(12));
            LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
            lp.bottomMargin = dp(8);
            row.setOnClickListener(v -> {
                urlInput.setText(u);
                urlInput.setSelection(urlInput.getText().length());
            });
            row.setOnLongClickListener(v -> {
                new AlertDialog.Builder(this)
                        .setTitle("删除这条记录?")
                        .setPositiveButton("删除", (d, w) -> {
                            List<String> list = getSavedUrls();
                            list.remove(u);
                            saveUrls(list);
                            refreshHistory();
                        })
                        .setNegativeButton("取消", null)
                        .show();
                return true;
            });
            historyBox.addView(row, lp);
        }
    }

    // =========================================================
    //  连接
    // =========================================================
    private void doConnect() {
        String raw = urlInput.getText().toString().trim();
        if (raw.isEmpty()) {
            Toast.makeText(this, "请先输入链接", Toast.LENGTH_SHORT).show();
            return;
        }
        String url = normalizeUrl(raw);
        if (url == null) {
            Toast.makeText(this, "链接格式不对,应以 http:// 或 https:// 开头", Toast.LENGTH_LONG).show();
            return;
        }
        prefs.edit().putString(KEY_LAST, url).apply();
        List<String> list = getSavedUrls();
        list.remove(url);
        list.add(0, url);
        while (list.size() > MAX_HISTORY) list.remove(list.size() - 1);
        saveUrls(list);

        connectTo(url);
    }

    private String normalizeUrl(String s) {
        s = s.trim();
        if (s.isEmpty()) return null;
        // 没写协议就补 http:// —— 这样 [ipv6]:port、1.2.3.4:port、主机名 都能处理
        if (!s.startsWith("http://") && !s.startsWith("https://")) {
            s = "http://" + s;
        }
        return s;
    }

    private void connectTo(final String url) {
        if (webView == null) {
            webView = new WebView(this);
            WebSettings s = webView.getSettings();
            s.setJavaScriptEnabled(true);
            s.setDomStorageEnabled(true);
            s.setDatabaseEnabled(true);
            s.setAllowFileAccess(false);
            s.setAllowContentAccess(false);
            s.setSupportZoom(true);
            s.setBuiltInZoomControls(true);
            s.setDisplayZoomControls(false);
            s.setUseWideViewPort(true);
            s.setLoadWithOverviewMode(true);
            s.setMediaPlaybackRequiresUserGesture(false);
            s.setSupportMultipleWindows(false);
            s.setJavaScriptCanOpenWindowsAutomatically(true);
            // 去掉 UA 里的 "; wv",避免被网页判定为不支持的 WebView
            String ua = s.getUserAgentString();
            if (ua != null) s.setUserAgentString(ua.replace("; wv", ""));
            webView.setBackgroundColor(C_BG);
            webView.setFocusable(true);
            webView.setFocusableInTouchMode(true);
            webView.requestFocus(View.FOCUS_DOWN);

            webView.setWebViewClient(new WebViewClient() {
                @Override
                public void onPageFinished(WebView view, String u) {
                    applyImmersive();
                    webView.requestFocus(View.FOCUS_DOWN);
                }

                // 自签证书必须放行,否则 WebView 默认会直接取消加载(表现为白屏)。
                // 本应用只用来访问用户自己的开发服务器,证书由本机每次启动自动生成,
                // 无法做固定指纹校验(证书每次都变),因此这里选择继续加载。
                @Override
                public void onReceivedSslError(WebView view, android.webkit.SslErrorHandler handler,
                                               android.net.http.SslError error) {
                    handler.proceed();
                }
            });

            webView.setWebChromeClient(new WebChromeClient() {
                @Override
                public void onProgressChanged(WebView view, int p) {
                    if (progress == null) return;
                    progress.setProgress(p);
                    progress.setVisibility(p >= 100 ? View.GONE : View.VISIBLE);
                }

                // 把 WebView 里的 JS 错误/警告打到 logcat,方便排查
                @Override
                public boolean onConsoleMessage(android.webkit.ConsoleMessage cm) {
                    String lvl = cm.messageLevel().name();
                    if (lvl.equals("ERROR") || lvl.equals("WARNING")) {
                        android.util.Log.e("CodeRemoteWV",
                            cm.message() + "  @" + cm.sourceId() + ":" + cm.lineNumber());
                    }
                    return true;
                }
            });

            root.addView(webView, new FrameLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

            progress = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal);
            progress.setMax(100);
            FrameLayout.LayoutParams pLp = new FrameLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, dp(3));
            pLp.gravity = Gravity.TOP;
            root.addView(progress, pLp);
        }

        inputScreen.setVisibility(View.GONE);
        webView.setVisibility(View.VISIBLE);
        progress.setVisibility(View.VISIBLE);
        progress.setProgress(0);
        connected = true;
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        applyImmersive();
        webView.loadUrl(url);
    }

    private void showInput() {
        connected = false;
        getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        if (webView != null) {
            webView.setVisibility(View.GONE);
            webView.stopLoading();
        }
        if (progress != null) progress.setVisibility(View.GONE);
        inputScreen.setVisibility(View.VISIBLE);
        showBars();
        refreshHistory();
    }

    // =========================================================
    //  沉浸 / 系统栏
    // =========================================================
    private void applyImmersive() {
        WindowCompat.setDecorFitsSystemWindows(getWindow(), false);
        WindowInsetsControllerCompat c =
                WindowCompat.getInsetsController(getWindow(), getWindow().getDecorView());
        c.hide(WindowInsetsCompat.Type.systemBars());
        c.setSystemBarsBehavior(
                WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE);
    }

    private void showBars() {
        WindowCompat.setDecorFitsSystemWindows(getWindow(), true);
        WindowInsetsControllerCompat c =
                WindowCompat.getInsetsController(getWindow(), getWindow().getDecorView());
        c.show(WindowInsetsCompat.Type.systemBars());
    }

    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (hasFocus && connected) applyImmersive();
    }

    // =========================================================
    //  返回键 / 生命周期
    // =========================================================
    @Override
    public void onBackPressed() {
        if (connected && webView != null && webView.canGoBack()) {
            webView.goBack();
            return;
        }
        if (connected) {
            new AlertDialog.Builder(this)
                    .setTitle("要退出吗?")
                    .setItems(new CharSequence[]{"换个链接", "退出应用"}, (d, which) -> {
                        if (which == 0) showInput();
                        else finish();
                    })
                    .setNegativeButton("继续使用", null)
                    .show();
            return;
        }
        super.onBackPressed();
    }

    @Override
    protected void onPause() {
        super.onPause();
        if (webView != null) webView.onPause();
    }

    @Override
    protected void onResume() {
        super.onResume();
        if (webView != null) webView.onResume();
        if (connected) applyImmersive();
    }

    @Override
    protected void onDestroy() {
        if (webView != null) {
            webView.loadUrl("about:blank");
            webView.destroy();
            webView = null;
        }
        super.onDestroy();
    }

    // =========================================================
    //  存储 / 剪贴板
    // =========================================================
    private List<String> getSavedUrls() {
        List<String> out = new ArrayList<>();
        String raw = prefs.getString(KEY_URLS, "");
        if (raw == null || raw.isEmpty()) return out;
        for (String line : raw.split("\n")) {
            if (!line.trim().isEmpty()) out.add(line.trim());
        }
        return out;
    }

    private void saveUrls(List<String> urls) {
        prefs.edit().putString(KEY_URLS, String.join("\n", urls)).apply();
    }

    private String readClipboard() {
        try {
            ClipboardManager cm = (ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
            if (cm == null || !cm.hasPrimaryClip()) return null;
            ClipData clip = cm.getPrimaryClip();
            if (clip == null || clip.getItemCount() == 0) return null;
            CharSequence text = clip.getItemAt(0).coerceToText(this);
            return text == null ? null : text.toString().trim();
        } catch (Exception e) {
            return null;
        }
    }

    private boolean looksLikeUrl(String s) {
        if (s == null) return false;
        String t = s.trim();
        return t.startsWith("http://") || t.startsWith("https://") || t.startsWith("[");
    }
}
