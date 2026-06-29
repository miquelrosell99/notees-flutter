# SQLCipher
-keep class net.sqlcipher.** { *; }

# WorkManager / Room generated database implementation used via reflection by
# androidx.startup.InitializationProvider. R8 in full mode strips the no-arg
# constructor, causing a crash on app launch.
-keep class androidx.work.impl.WorkDatabase_Impl { *; }
-keep class * extends androidx.work.ListenableWorker {
    <init>(android.content.Context, androidx.work.WorkerParameters);
}
-dontwarn androidx.work.**
