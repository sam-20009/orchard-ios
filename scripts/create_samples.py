from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED
import sys
root=Path(sys.argv[1]);root.mkdir(parents=True,exist_ok=True)
examples={
    'valid.apk':['AndroidManifest.xml','lib/arm64-v8a/libopenxr_loader.so'],
    'valid.ipa':['Payload/Test.app/Info.plist'],
    'valid.pxr':['manifest.json','payload/android/game.apk','payload/ios/game.ipa'],
    'valid.zip':['hello.txt']
}
for filename, names in examples.items():
    with ZipFile(root/filename,'w',ZIP_DEFLATED) as zipf:
        for name in names: zipf.writestr(name, 'test fixture')
(root/'broken.apk').write_bytes(b'not a zip')
print('Generated',len(examples)+1,'test fixture archives.')
