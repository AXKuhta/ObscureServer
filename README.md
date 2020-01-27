# ObscureServer

A small HTTP + WebDAV server written in BlitzMaxNG. 

It is by no means complete, implementing only the most basic stuff and not really adhering to RFCs. 

It *was* tested in the wild and can withstand the traffic of the usual web scanners and crawlers just fine. There are various security checks in place that should prevent the unintended leakage of information. Nevertheless, the risk from using this thing in the open web is still on you.

## Capabilities

- Supports multiple simultaneous users
- Can handle large (>4GB) files
- Supports ranges (i.e. download resume)
- Supports uploads
- Supports Keep-Alive connections
- Supports gzip and zstd compression
- Compressed files can be cached

The following list of tested software should give you an idea about the server's overall state;
#### Media streaming:
- VLC:
  Streaming and timeskipping works.

#### WebDAV:
- [CarotDAV](http://rei.to/carotdav_en.html):
  File downloads, upload, renames and removes work. WebDAV XML compression also works.
  
- MiXPlorer:
  Fails if compression is enabled, otherwise works but still janky.
  
- WinSCP:
  Works but janky. Doesn't use compression at all.
  
#### Web pages:
- [TiddlyWiki](https://tiddlywiki.com) (singlefile):
  If WebDAV is enabled, TiddlyWiki can determine that the server allows PUT requests, and save-to-server functionality starts working.
 
- [dump1090](https://github.com/flightaware/dump1090) webUI:
  Parameters embedded into the URL get ignored, but otherwise it works.

## Building

Any recent version of BlitzMaxNG should work (This code will not compile on classic BlitzMax!)

Additionally it needs [BaH.zstd](https://github.com/maxmods/bah.mod/tree/master/zstd.mod). If you don't want to download the entire bah.mod repository just to use this single module, I can provide you with a [standalone copy](https://drive.google.com/open?id=19bKMtVVkFGps5XnjB8qLUGs5liB_vE72) (zstd version 1.4.3). Extract the contents into the mod directory of your BlitzMax installation.

On Windows, open the Srv.bmx in MaxIDE and build it in non-debug non-gui mode.

On Linux, you can also build with MaxIDE, or if you don't want to install all of the dependencies needed to run it you can build directly with bmk:
```
$ git clone https://github.com/AXKuhta/ObscureServer
$ cd ObscureServer
$ ~/BlitzMax/bin/bmk makeapp -w Srv.bmx
```
