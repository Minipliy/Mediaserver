#!/usr/bin/env python3
"""Create original review-only media; never read the user's media directory."""
from pathlib import Path
import math, struct, wave, subprocess, shutil
root=Path(__file__).resolve().parents[1]/'build/review-media'
music=root/'Musik/Mediaserver Studio/Klangskizzen'; music.mkdir(parents=True,exist_ok=True)
for title,freq in [('Morgenlicht',220),('Blaue Stunde',196),('Unterwegs',261.63)]:
 wav=music/(title+'.wav')
 with wave.open(str(wav),'wb') as out:
  out.setparams((1,2,22050,0,'NONE','not compressed'))
  out.writeframes(b''.join(struct.pack('<h',int(1400*min(1,n/22050,(22050*24-n)/22050)*(math.sin(2*math.pi*freq*n/22050)+.35*math.sin(2*math.pi*freq*1.5*n/22050)))) for n in range(22050*24)))
 subprocess.run(['ffmpeg','-v','error','-y','-i',str(wav),'-c:a','aac','-b:a','96k','-metadata','title='+title,'-metadata','artist=Mediaserver Studio','-metadata','album=Klangskizzen',str(music/(title+'.m4a'))],check=True)
 wav.unlink()
video=root/'Filme/Farbspiel.mp4'; video.parent.mkdir(parents=True,exist_ok=True)
subprocess.run(['ffmpeg','-v','error','-y','-f','lavfi','-i','testsrc2=size=1280x720:rate=24','-t','20','-c:v','libx264','-preset','fast','-crf','26','-pix_fmt','yuv420p','-movflags','+faststart','-metadata','title=Farbspiel – Originale Testanimation',str(video)],check=True)
episode=root/'Serien/Studio Miniaturen/Staffel 01/S01E01 - Farbspiel.mp4'; episode.parent.mkdir(parents=True,exist_ok=True); shutil.copyfile(video,episode)
docs=root/'Dokumente'; docs.mkdir(exist_ok=True)
(docs/'Zur Demo.txt').write_text('Mediaserver App Review\nAlle Klangskizzen und Testanimationen wurden eigens synthetisch erzeugt. Keine fremden Medien.\nDieser gemeinsame Testzugang enthält keine privaten Nutzerdaten. Bitte keine persönlichen Informationen eintragen.\n')
# Version 1.1: cover, poster, lyrics, subtitles and a second season, all
# generated here (fractal images, own text) - no third-party material.
def still(target, size, region):
 subprocess.run(['ffmpeg','-v','error','-y','-f','lavfi','-i',f'mandelbrot=size={size}:start_scale={region}:end_scale={region}','-frames:v','1','-q:v','3',str(target)],check=True)
still(music/'cover.jpg','600x600',0.8)
still(video.with_suffix('.jpg'),'600x900',0.3)
still(root/'Serien/Studio Miniaturen/poster.jpg','600x900',1.6)
(music/'Morgenlicht.lrc').write_text('[ar:Mediaserver Studio]\n[ti:Morgenlicht]\n[00:01.00]Erstes Licht über dem Dach\n[00:05.00]die Stadt ist noch leise\n[00:09.00]ein Ton, der sich langsam hebt\n[00:13.00]und dann ein zweiter dazu\n[00:17.00]Morgenlicht, Morgenlicht\n[00:21.00]der Tag fängt an\n',encoding='utf-8')
subtitle='1\n00:00:01,000 --> 00:00:05,000\nFarbspiel – eine Testanimation\n\n2\n00:00:06,000 --> 00:00:11,000\nAlle Bilder wurden eigens erzeugt.\n\n3\n00:00:12,000 --> 00:00:18,000\nUntertitel aus einer .srt-Datei neben dem Video.\n'
video.with_suffix('.de.srt').write_text(subtitle,encoding='utf-8')
episode.with_suffix('.de.srt').write_text(subtitle,encoding='utf-8')
second=root/'Serien/Studio Miniaturen/Staffel 02/S02E01 - Farbspiel Reprise.mp4'; second.parent.mkdir(parents=True,exist_ok=True); shutil.copyfile(video,second)
print('Originale Demo-Dateien:',root)
