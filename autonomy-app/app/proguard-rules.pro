# Room generates implementation classes referenced by name at runtime.
-keep class * extends androidx.room.RoomDatabase { <init>(); }
-keepclassmembers class * extends androidx.room.RoomDatabase { public static ** newInstance(...); }
