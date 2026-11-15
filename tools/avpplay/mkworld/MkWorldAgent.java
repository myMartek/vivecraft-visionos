// MkWorldAgent: javaagent for ONE unattended world-creation run before the Knot bake (tools/avpplay/build_parts.sh,
// stage "world"). It is never used in the bake run, never placed in mods/ and never on a baked classpath; the jar is
// built into the work folder, outside the instance. It replaces the clicks BUILDING.md section 6 describes:
//   Singleplayer -> Create New World -> name "world" -> wait for terrain -> Save and Quit to Title -> quit.
// It does that with the game's own calls, on the client thread:
//   CreateWorldScreen.openFresh(mc, onClose)            (what "Create New World" opens; default settings)
//   screen.getUiState().setName("world")                (the name field)
//   CreateWorldScreen.onCreate()                        (the "Create New World" button; private, via reflection)
//   mc.disconnectFromWorld(ClientLevel.DEFAULT_QUIT_MESSAGE)   (the "Save and Quit to Title" button)
//   mc.stop()                                           (Quit Game)
// The names are those of the unobfuscated Minecraft 26.3 client. Reflection only: this file compiles without the
// game on the classpath, and no Minecraft class is loaded by the agent before the game itself has loaded
// net.minecraft.client.Minecraft (so Knot and Mixin see the normal order).
// Every step prints a "[MKWORLD] ..." line; the last one is "[MKWORLD] DONE; stopping the game". A failed step
// prints "[MKWORLD] FAILED: ..." and the game is stopped where that is possible.
// Usage: -javaagent:mkworld-agent.jar[=<seconds in world, default 30>]
import java.lang.instrument.Instrumentation;
import java.lang.reflect.Field;
import java.lang.reflect.Method;

public class MkWorldAgent {
  static Instrumentation inst;
  static int stay = 30;
  static final String MC = "net.minecraft.client.Minecraft";
  static final String TITLE = "net.minecraft.client.gui.screens.TitleScreen";
  static final String CWS = "net.minecraft.client.gui.screens.worldselection.CreateWorldScreen";

  public static void premain(String args, Instrumentation i) {
    inst = i;
    if (args != null && !args.isEmpty()) stay = Integer.parseInt(args.trim());
    Thread t = new Thread(() -> {
      try { run(); } catch (Throwable e) { log("FAILED: " + e); e.printStackTrace(System.out); System.out.flush(); }
    }, "mkworld");
    t.setDaemon(true);
    t.start();
  }

  static void log(String s) { System.out.println("[MKWORLD] " + s); System.out.flush(); }

  static Class<?> loadedMinecraft() {
    for (Class<?> c : inst.getAllLoadedClasses()) {
      if (c.getName().equals(MC) && c.getClassLoader() != null
          && c.getClassLoader().getClass().getName().contains("KnotClassLoader")) return c;
    }
    return null;
  }

  static Object mc; static Class<?> mcC; static Object gui;

  static Object screen() throws Exception { return gui.getClass().getMethod("screen").invoke(gui); }
  static Object overlay() throws Exception { return gui.getClass().getMethod("overlay").invoke(gui); }
  static Object field(String n) throws Exception { return mcC.getField(n).get(mc); }
  static String cn(Object o) { return o == null ? "null" : o.getClass().getName(); }
  static void onClient(Runnable r) throws Exception { mcC.getMethod("execute", Runnable.class).invoke(mc, r); }

  static void run() throws Exception {
    // 1. wait until the game has loaded and constructed Minecraft
    long t0 = System.currentTimeMillis();
    while ((mcC = loadedMinecraft()) == null) {
      if (System.currentTimeMillis() - t0 > 240_000) { log("FAILED: Minecraft class never loaded"); return; }
      Thread.sleep(1000);
    }
    log("Minecraft class loaded by " + mcC.getClassLoader().getClass().getName());
    Method getInstance = mcC.getMethod("getInstance");
    while (true) {
      mc = getInstance.invoke(null);
      if (mc != null) { gui = mcC.getField("gui").get(mc); if (gui != null) break; }
      if (System.currentTimeMillis() - t0 > 300_000) { log("FAILED: no Minecraft instance / gui"); return; }
      Thread.sleep(500);
    }
    log("Minecraft instance ready");

    // 2. wait for the title screen with no loading overlay, stable for 3 s
    String last = ""; int stable = 0; long t1 = System.currentTimeMillis();
    while (stable < 6) {
      String s = cn(screen()) + " overlay=" + cn(overlay());
      if (!s.equals(last)) { log("screen: " + s); last = s; }
      stable = (overlay() == null && cn(screen()).equals(TITLE)) ? stable + 1 : 0;
      if (System.currentTimeMillis() - t1 > 300_000) { log("FAILED: title screen not reached; last " + s); quit(); return; }
      Thread.sleep(500);
    }
    log("title screen reached");

    // 3. create and open the world, on the client thread, with the game's own create-world screen at its defaults
    final ClassLoader knot = mcC.getClassLoader();
    final boolean[] started = { false };
    onClient(() -> {
      try {
        Class<?> cws = Class.forName(CWS, true, knot);
        Runnable onClose = () -> log("create-world screen onClose callback ran");
        cws.getMethod("openFresh", mcC, Runnable.class).invoke(null, mc, onClose);
        Object scr = screen();
        log("after openFresh: screen=" + cn(scr));
        if (!cws.isInstance(scr)) { log("FAILED: create-world screen did not open"); return; }
        Object ui = cws.getMethod("getUiState").invoke(scr);
        ui.getClass().getMethod("setName", String.class).invoke(ui, "world");
        log("name=" + ui.getClass().getMethod("getName").invoke(ui)
            + " targetFolder=" + ui.getClass().getMethod("getTargetFolder").invoke(ui)
            + " gameMode=" + ui.getClass().getMethod("getGameMode").invoke(ui)
            + " difficulty=" + ui.getClass().getMethod("getDifficulty").invoke(ui)
            + " worldType=" + describeWorldType(ui));
        Method onCreate = cws.getDeclaredMethod("onCreate");
        onCreate.setAccessible(true);
        onCreate.invoke(scr);
        started[0] = true;
        log("onCreate returned; screen=" + cn(screen()));
      } catch (Throwable e) {
        log("FAILED in create: " + e); e.printStackTrace(System.out); System.out.flush();
      }
    });

    // 4. wait until the player is in the world
    long t2 = System.currentTimeMillis(); last = "";
    while (true) {
      Object player = field("player"), level = field("level");
      String s = cn(screen()) + " player=" + (player != null) + " level=" + (level != null);
      if (!s.equals(last)) { log("state: " + s); last = s; }
      if (player != null && level != null && started[0]) break;
      if (System.currentTimeMillis() - t2 > 300_000) { log("FAILED: player never entered the world; last " + s); quit(); return; }
      Thread.sleep(500);
    }
    log("player is in the world; staying " + stay + " s");
    for (int k = 0; k < stay; k++) {
      Thread.sleep(1000);
      String s = cn(screen()) + " player=" + (field("player") != null) + " level=" + (field("level") != null);
      if (!s.equals(last)) { log("state: " + s); last = s; }
    }

    // 5. Save and Quit to Title (the pause screen button's call), then quit the game
    log("saving and quitting to title");
    onClient(() -> {
      try {
        Class<?> cl = Class.forName("net.minecraft.client.multiplayer.ClientLevel", true, knot);
        Object msg = cl.getField("DEFAULT_QUIT_MESSAGE").get(null);
        Class<?> comp = Class.forName("net.minecraft.network.chat.Component", true, knot);
        mcC.getMethod("disconnectFromWorld", comp).invoke(mc, msg);
        log("disconnectFromWorld returned; screen=" + cn(screen()));
      } catch (Throwable e) {
        log("FAILED in save-and-quit: " + e); e.printStackTrace(System.out); System.out.flush();
      }
    });
    long t3 = System.currentTimeMillis();
    while (true) {
      boolean sp = (Boolean) mcC.getMethod("hasSingleplayerServer").invoke(mc);
      String s = cn(screen()) + " level=" + (field("level") != null) + " singleplayerServer=" + sp;
      if (!s.equals(last)) { log("state: " + s); last = s; }
      if (field("level") == null && !sp && cn(screen()).equals(TITLE)) break;
      if (System.currentTimeMillis() - t3 > 120_000) { log("WARNING: title screen not reached after save; quitting anyway"); break; }
      Thread.sleep(500);
    }
    Thread.sleep(3000);
    log("DONE; stopping the game");
    quit();
  }

  static String describeWorldType(Object ui) {
    try {
      Object wt = ui.getClass().getMethod("getWorldType").invoke(ui);
      Object preset = wt.getClass().getMethod("preset").invoke(wt);
      return String.valueOf(preset);
    } catch (Throwable e) { return "?(" + e + ")"; }
  }

  static void quit() throws Exception {
    onClient(() -> { try { mcC.getMethod("stop").invoke(mc); } catch (Throwable e) { log("stop failed: " + e); } });
  }
}
