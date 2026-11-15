// BakeAgent: javaagent for the Fabric/Knot JVM run. Produces the post-Knot (remap + access widener +
// game-provider entrypoint patch + Mixin) bytes of every game/mod class, so a closed-world build can
// run without Knot or Mixin.
//   -javaagent:bakeagent.jar=<outdir>   -Dbake.fullAt=<seconds> (default 40)
// 1) ClassFileTransformer: every class DEFINED by KnotClassLoader -> <out>/classes/<name>.class
//    (these are the exact bytes passed to defineClass); every class defined by any OTHER non-JDK loader
//    is logged to <out>/other-loaders.txt (runtime class generation detector).
// 2) At fullAt seconds: walk FabricLauncher.getClassPath() and push every not-yet-defined class through
//    KnotClassDelegate.getPostMixinClassByteArray(name,false) WITHOUT defining it -> <out>/classes/.
//    Non-interface @Mixin classes are skipped (Mixin forbids loading them); mixin interfaces (accessors)
//    are kept as raw bytes.
// 3) Then the classes Mixin/MixinExtras only generate when their name is first asked for (inner classes of mixins
//    copied into their targets, @ModifyArgs Args classes, MixinExtras' generated classes): every name in Mixin's
//    synthetic class registry and every referenced name no class file provides, until closure (see fullPass).
//    Records: synthetic-classes.txt, generated-classes.txt, unresolved-refs.txt, synthetic-summary.txt.
import java.lang.instrument.*;
import java.lang.reflect.*;
import java.nio.file.*;
import java.security.ProtectionDomain;
import java.util.*;
import java.util.concurrent.ConcurrentHashMap;
import java.util.stream.*;

public class BakeAgent {
  static Path out;
  static final Set<String> defined = ConcurrentHashMap.newKeySet();
  static final Map<String, Integer> otherLoaders = new ConcurrentHashMap<>();

  public static void premain(String args, Instrumentation inst) throws Exception {
    out = Paths.get(args == null ? "bake" : args);
    Files.createDirectories(out.resolve("classes"));
    inst.addTransformer(new ClassFileTransformer() {
      public byte[] transform(ClassLoader l, String name, Class<?> redefined, ProtectionDomain pd, byte[] b) {
        if (l == null || name == null) return null;
        String ln = l.getClass().getName();
        if (ln.contains("KnotClassLoader")) {
          write(name, b); defined.add(name);
        } else if (!ln.startsWith("jdk.internal.loader.") && !ln.equals("jdk.internal.reflect.DelegatingClassLoader")) {
          otherLoaders.merge(ln + " :: " + name, 1, Integer::sum);
        }
        return null;
      }
    });
    long at = Long.getLong("bake.fullAt", 40);
    Thread t = new Thread(() -> {
      try { Thread.sleep(at * 1000); fullPass(); } catch (Throwable e) { e.printStackTrace(); }
    }, "bake-fullpass");
    t.setDaemon(true); t.start();
  }

  static void write(String name, byte[] b) {
    try {
      Path p = out.resolve("classes").resolve(name + ".class");
      Files.createDirectories(p.getParent());
      Files.write(p, b);
    } catch (Exception e) { e.printStackTrace(); }
  }

  static Set<String> classNames() throws Exception {
    Path root = out.resolve("classes");
    try (Stream<Path> s = Files.walk(root)) {
      return s.filter(x -> x.toString().endsWith(".class")).map(x -> { String r = root.relativize(x).toString(); return r.substring(0, r.length() - 6); })
          .collect(Collectors.toCollection(TreeSet::new));
    }
  }

  // Mixin's synthetic class registry (sponge-mixin 0.17: MixinTransformer.syntheticClassRegistry, a
  // SyntheticClassRegistry with a private Map<String, ISyntheticClassInfo> "classes" keyed by internal name), reached
  // through the public IMixinTransformer.getExtensions().getSyntheticClassRegistry(). The map itself has no public
  // accessor, so it is read by reflection. Returns internal name -> mixin. With a log, a failure to read it is a
  // GEN-FAIL line (the build stops on it: without the registry the capture cannot be complete).
  static Map<String, String> syntheticRegistry(Object delegate, List<String> log) {
    Map<String, String> res = new TreeMap<>();
    try {
      Method gt = delegate.getClass().getDeclaredMethod("getMixinTransformer"); gt.setAccessible(true);
      Object tr = gt.invoke(delegate);
      ClassLoader ml = tr.getClass().getClassLoader();
      Class<?> imt = Class.forName("org.spongepowered.asm.mixin.transformer.IMixinTransformer", false, ml);
      Class<?> ier = Class.forName("org.spongepowered.asm.mixin.transformer.ext.IExtensionRegistry", false, ml);
      Class<?> isi = Class.forName("org.spongepowered.asm.service.ISyntheticClassInfo", false, ml);
      Object ext = imt.getMethod("getExtensions").invoke(tr);
      Object reg = ier.getMethod("getSyntheticClassRegistry").invoke(ext);
      Field cf = reg.getClass().getDeclaredField("classes"); cf.setAccessible(true);
      Map<?, ?> m = (Map<?, ?>) cf.get(reg);
      List<Object> infos;
      for (int i = 0; ; i++) {
        try { synchronized (m) { infos = new ArrayList<>(m.values()); } break; }
        catch (ConcurrentModificationException e) { if (i > 50) throw e; Thread.sleep(20); }
      }
      Method gn = isi.getMethod("getName"), gm = isi.getMethod("getMixin");
      for (Object info : infos) res.put(((String) gn.invoke(info)).replace('.', '/'), String.valueOf(gm.invoke(info)));
    } catch (Throwable e) {
      Throwable c = e instanceof InvocationTargetException ? e.getCause() : e;
      if (log != null) log.add("GEN-FAIL <mixin synthetic class registry> :: " + c);
    }
    return res;
  }

  static boolean isMixinNonInterface(byte[] raw) {
    String s = new String(raw, java.nio.charset.StandardCharsets.ISO_8859_1);
    if (!s.contains("Lorg/spongepowered/asm/mixin/Mixin;")) return false;
    // access_flags follow the constant pool; cheap check via ASM is safer
    org.objectweb.asm.ClassReader cr = new org.objectweb.asm.ClassReader(raw);
    return (cr.getAccess() & org.objectweb.asm.Opcodes.ACC_INTERFACE) == 0;
  }

  static void fullPass() throws Exception {
    ClassLoader cl = Thread.currentThread().getContextClassLoader();
    Class<?> flb = Class.forName("net.fabricmc.loader.impl.launch.FabricLauncherBase", true, ClassLoader.getSystemClassLoader());
    Object launcher = flb.getMethod("getLauncher").invoke(null);
    ClassLoader knot = (ClassLoader) launcher.getClass().getMethod("getTargetClassLoader").invoke(launcher);
    Method gd = knot.getClass().getDeclaredMethod("getDelegate"); gd.setAccessible(true);
    Object delegate = gd.invoke(knot);
    // Knot's own code sources (remapped game jar, mods, extracted nested jars) -- NOT the launcher's -cp
    Field csf = delegate.getClass().getDeclaredField("codeSources"); csf.setAccessible(true);
    @SuppressWarnings("unchecked")
    List<Path> cp = new ArrayList<>((Set<Path>) csf.get(delegate));
    Method post = delegate.getClass().getDeclaredMethod("getPostMixinClassByteArray", String.class, boolean.class); post.setAccessible(true);
    Method raw = delegate.getClass().getDeclaredMethod("getRawClassByteArray", String.class, boolean.class); raw.setAccessible(true);
    List<String> log = new ArrayList<>();
    int ok = 0, skippedMixin = 0, already = 0, fail = 0, nul = 0;
    List<String> cpLines = new ArrayList<>();
    for (Path p : cp) {
      cpLines.add(p.toString());
      List<String> names = new ArrayList<>();
      if (Files.isDirectory(p)) {
        try (Stream<Path> s = Files.walk(p)) { s.filter(x -> x.toString().endsWith(".class")).forEach(x -> names.add(p.relativize(x).toString())); }
      } else if (p.toString().endsWith(".jar")) {
        try (java.util.zip.ZipFile z = new java.util.zip.ZipFile(p.toFile())) {
          z.stream().map(e -> e.getName()).filter(n -> n.endsWith(".class") && !n.startsWith("META-INF/")).forEach(names::add);
        }
      }
      for (String f : names) {
        String in = f.substring(0, f.length() - 6);
        if (in.equals("module-info") || in.endsWith("package-info")) continue;
        if (defined.contains(in)) { already++; continue; }
        String dn = in.replace('/', '.');
        try {
          byte[] r = (byte[]) raw.invoke(delegate, dn, false);
          if (r == null) { nul++; continue; }
          if (isMixinNonInterface(r)) { skippedMixin++; continue; }
          byte[] b = (byte[]) post.invoke(delegate, dn, false);
          if (b == null) { nul++; continue; }
          write(in, b); ok++;
        } catch (Throwable e) {
          fail++;
          Throwable c = e instanceof InvocationTargetException ? e.getCause() : e;
          log.add(in + " :: " + c);
        }
      }
    }
    // 3) generated classes: classes that exist only once Mixin (or MixinExtras) writes them, on the first request for
    //    their name. Mixin copies every inner class of a mixin (anonymous, local, named inner) into the target's
    //    package: `Target$Anonymous$<uuid>` for an anonymous class, `Target$<Name>$<uuid>` for a named one (such as
    //    fabric-creative-tab-api's local record CreativeModeTabsMixin$1CreativeModeTabPosition, which becomes
    //    CreativeModeTabs$1CreativeModeTabPosition$<uuid>); @ModifyArgs adds `.../synthetic/args/Args$<n>` classes;
    //    MixinExtras adds `.../generated/...` classes. A class nobody asked for during the run was never written, so it
    //    is neither in the overlay nor in the image, and the image throws NoClassDefFoundError where the game uses it.
    //    Each round asks Knot (which hands a name without a class file to Mixin's class generators, exactly as when the
    //    game loads it) for
    //    a) every class in Mixin's synthetic class registry (IMixinTransformer.getExtensions()
    //       .getSyntheticClassRegistry()): Mixin enters each inner class and Args class there when it applies the
    //       mixin that needs it, so after the full pass it names all of them, referenced or not yet;
    //    b) every class name in the constant pool of a captured class that no class file on Knot's class path, the
    //       launcher's class path or the JDK provides (names with $Anonymous$, /generated/ or synthetic/args always;
    //       the generic case covers generators that keep no registry).
    //    Only names with no class file yet are asked for, and only new files are written, so nothing captured before is
    //    changed. A registered class Knot cannot produce is a GEN- line in fullpass-failures.txt (the build fails on
    //    it). A referenced name nothing provides is listed in unresolved-refs.txt with one class that refers to it.
    Map<String, String> synth = syntheticRegistry(delegate, log);   // internal name -> mixin
    Set<String> definedBefore = new HashSet<>(defined);
    Set<String> haveBeforeGen = classNames();
    int gen = 0, genReg = 0, genRef = 0, rounds = 0;
    Set<String> asked = new HashSet<>();
    Map<String, String> unresolved = new TreeMap<>();
    Map<String, Boolean> onClassPath = new HashMap<>();   // a class file for the name on Knot's or the launcher's class path, or in the JDK
    for (int round = 0; round < 20; round++) {
      rounds = round + 1;
      Set<String> have = classNames();
      Map<String, String> want = new TreeMap<>();   // name -> why
      synth.putAll(syntheticRegistry(delegate, null));
      for (String n : synth.keySet()) if (!have.contains(n) && !asked.contains(n)) want.put(n, "registry");
      unresolved.clear();
      for (String self : have) {
        Path f = out.resolve("classes").resolve(self + ".class");
        org.objectweb.asm.ClassReader cr = new org.objectweb.asm.ClassReader(Files.readAllBytes(f));
        char[] buf = new char[cr.getMaxStringLength()];
        for (int i = 1; i < cr.getItemCount(); i++) {
          int off = cr.getItem(i);
          if (off > 0 && cr.readByte(off - 1) == 7) {
            String n = cr.readUTF8(off, buf);
            if (n == null || n.startsWith("[") || have.contains(n) || want.containsKey(n)) continue;
            if (asked.contains(n)) { unresolved.putIfAbsent(n, self); continue; }
            boolean named = n.contains("$Anonymous$") || n.contains("/generated/") || n.contains("synthetic/args");
            if (named || !onClassPath.computeIfAbsent(n, x -> knot.getResource(x + ".class") != null)) want.put(n, named ? "named" : "ref");
          }
        }
      }
      if (want.isEmpty()) break;
      for (Map.Entry<String, String> w : want.entrySet()) {
        String n = w.getKey();
        asked.add(n);
        try {
          byte[] b = (byte[]) post.invoke(delegate, n.replace('/', '.'), false);
          if (b != null) {
            write(n, b); gen++;
            if (synth.containsKey(n)) genReg++; else genRef++;
          } else if (!w.getValue().equals("ref")) log.add("GEN-NULL " + n);
        } catch (Throwable e) {
          Throwable c = e instanceof InvocationTargetException ? e.getCause() : e;
          if (!w.getValue().equals("ref")) log.add("GEN-FAIL " + n + " :: " + c);
          else unresolved.putIfAbsent(n, "(Knot: " + c + ")");
        }
      }
    }
    // the record: every registered synthetic class and how it got into the overlay
    Set<String> haveNow = classNames();
    List<String> synthLines = new ArrayList<>();
    int sRuntime = 0, sBefore = 0, sNow = 0, sMissing = 0;
    for (Map.Entry<String, String> e : new TreeMap<>(synth).entrySet()) {
      String n = e.getKey(), how;
      if (definedBefore.contains(n)) { how = "defined-at-runtime"; sRuntime++; }
      else if (haveBeforeGen.contains(n)) { how = "captured-before"; sBefore++; }
      else if (haveNow.contains(n)) { how = "generated-by-bake"; sNow++; }
      else { how = "MISSING"; sMissing++; }
      synthLines.add(n + " " + how + " " + e.getValue());
    }
    Files.write(out.resolve("synthetic-classes.txt"), synthLines);
    List<String> genLines = new ArrayList<>();
    // (a class the game itself loaded while this step ran is in the overlay through the transformer, not through here)
    for (String n : haveNow) if (!haveBeforeGen.contains(n)) genLines.add(n + (defined.contains(n) ? " defined-at-runtime" : synth.containsKey(n) ? " registry" : " reference"));
    Collections.sort(genLines);
    Files.write(out.resolve("generated-classes.txt"), genLines);
    List<String> ur = new ArrayList<>();
    for (Map.Entry<String, String> e : unresolved.entrySet()) ur.add(e.getKey() + " <- " + e.getValue());
    Files.write(out.resolve("unresolved-refs.txt"), ur);
    String synthSummary = "[BAKE] mixin synthetic classes: registered=" + synth.size() + " defined-at-runtime=" + sRuntime
        + " captured-before=" + sBefore + " generated-by-bake=" + sNow + " missing=" + sMissing
        + " | generated classes written=" + gen + " (registry " + genReg + ", references " + genRef + ") rounds=" + rounds
        + " | unresolved references=" + unresolved.size();
    Files.write(out.resolve("synthetic-summary.txt"), List.of(synthSummary));
    System.out.println(synthSummary);
    System.out.println("[BAKE] generated classes recovered: " + gen);
    Files.write(out.resolve("knot-classpath.txt"), cpLines);
    Files.write(out.resolve("fullpass-failures.txt"), log);
    List<String> ol = otherLoaders.entrySet().stream().map(e -> e.getKey() + " x" + e.getValue()).sorted().collect(Collectors.toList());
    Files.write(out.resolve("other-loaders.txt"), ol);
    String summary = "[BAKE] defined-at-runtime=" + defined.size() + " fullpass-transformed=" + ok + " already=" + already
        + " skipped-mixin-classes=" + skippedMixin + " null=" + nul + " failed=" + fail + " other-loader-classes=" + ol.size();
    Files.write(out.resolve("summary.txt"), List.of(summary));
    System.out.println(summary);
  }
}
