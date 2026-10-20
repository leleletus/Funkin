package nx;

/**
 * Where the official game files live on Switch.
 *
 * Builds with the files inside the .nro read them from RomFS ("romfs:/assets/..."). Builds made with -DNX_SD_ASSETS
 * (the public build without FunkinCrew files, filled by the asset installer) read them from the SD card, where
 * "assets/" keeps the layout of the official FunkinCrew/funkin.assets repository.
 */
class NXAssetRoot
{
  /**
   * Folder that contains "assets/", with a trailing slash.
   */
  public static final ROOT:String = #if NX_SD_ASSETS 'sdmc:/switch/Friday-Night-Funkin/' #else 'romfs:/' #end;

  /**
   * Full path of a file given relative to the asset root, e.g. path('assets/week1/x.png').
   */
  public static inline function path(relative:String):String
  {
    return ROOT + relative;
  }

  /**
   * Full path of the official cutscene video `fileName` (with its extension). In RomFS builds the video is copied to
   * assets/videos/native; on the SD card it stays where the official repository keeps it, videos/videos.
   */
  public static inline function cutsceneVideo(fileName:String):String
  {
    return ROOT + #if NX_SD_ASSETS 'assets/videos/videos/' #else 'assets/videos/native/' #end + fileName;
  }
}
