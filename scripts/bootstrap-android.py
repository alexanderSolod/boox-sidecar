#!/usr/bin/env python3
"""Download checksum-verified Android build prerequisites inside this project."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import hashlib, subprocess, urllib.request, zipfile, shutil
ROOT=Path(__file__).resolve().parents[1]
TOOLS=ROOT/'.tools'; DOWNLOADS=TOOLS/'downloads'; DOWNLOADS.mkdir(parents=True,exist_ok=True)
ASSETS=[
 ('jdk.tar.gz','https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.21%2B9/OpenJDK17U-jdk_aarch64_mac_hotspot_17.0.21_9.tar.gz','sha256','78b08c7f5a0598242d5719c022e19479cb4a3aa45c37c19726a757a469ed1c15'),
 ('gradle.zip','https://services.gradle.org/distributions/gradle-8.9-bin.zip','sha256','d725d707bfabd4dfdc958c624003b3c80accc03f7037b5122c4b1d0ef15cecab'),
 ('platform.zip','https://dl.google.com/android/repository/platform-35_r02.zip','sha1','0bb560a90a7a2cbd0dd8348224d518b638fe7949'),
 ('build-tools.zip','https://dl.google.com/android/repository/build-tools_r35_macosx.zip','sha1','93ab8ce91230e067b5add4bfa79919c52b27f072')]
def download(asset):
 name,url,algo,digest=asset; dest=DOWNLOADS/name
 if not dest.exists():
  print('Downloading '+name,flush=True)
  subprocess.run(['curl','-fLsS','--retry','3','--max-time','300',url,'-o',str(dest)],check=True)
 if hashlib.new(algo,dest.read_bytes()).hexdigest()!=digest: raise RuntimeError('Checksum mismatch: '+name)
 print('Verified '+name,flush=True)
 return dest
with ThreadPoolExecutor(max_workers=4) as pool: list(pool.map(download,ASSETS))
if not (TOOLS/'jdk').exists():
 stage=TOOLS/'jdk-unpack'; stage.mkdir(exist_ok=True)
 subprocess.run(['tar','-xzf',str(DOWNLOADS/'jdk.tar.gz'),'-C',str(stage)],check=True)
 shutil.move(str(next(stage.iterdir())),str(TOOLS/'jdk'))
if not (TOOLS/'gradle-8.9').exists(): subprocess.run(['unzip','-q',str(DOWNLOADS/'gradle.zip'),'-d',str(TOOLS)],check=True)
for archive,relative in [('platform.zip','platforms/android-35'),('build-tools.zip','build-tools/35.0.0')]:
 target=TOOLS/'android-sdk'/relative
 if not target.exists():
  stage=TOOLS/(archive+'-unpack'); stage.mkdir(exist_ok=True)
  subprocess.run(['unzip','-q',str(DOWNLOADS/archive),'-d',str(stage)],check=True)
  target.parent.mkdir(parents=True,exist_ok=True)
  shutil.move(str(next(stage.iterdir())),str(target))
print('JAVA_HOME='+str(TOOLS/'jdk/Contents/Home'))
print('ANDROID_HOME='+str(TOOLS/'android-sdk'))
print('Gradle: '+str(TOOLS/'gradle-8.9/bin/gradle'))
