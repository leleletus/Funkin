#!/usr/bin/env python3
"""
tools/nx-tools/convert_video.py

Pipeline de conversión de cinemáticas para Nintendo Switch en Friday Night Funkin'.
Convierte archivos de vídeo (.mp4, .mkv, .webm) a una secuencia de atlas Sparrow (.png + .xml)
a 24 FPS / 720p junto con la pista de audio Vorbis (.ogg) sincronizada.

Uso:
    python tools/nx-tools/convert_video.py --input assets/videos/stressPicoCutscene.mkv --output assets/videos/converted/stressPicoCutscene

Requisitos:
    - ffmpeg instalado en el sistema
    - Pillow (PIL) para empaquetar los spritesheets
"""

import argparse
import math
import os
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from xml.dom import minidom

try:
    from PIL import Image
except ImportError:
    print("Error: Pillow no está instalado. Ejecuta: pip install Pillow")
    sys.exit(1)


def check_ffmpeg():
    if shutil.which("ffmpeg") is None:
        print("Error: ffmpeg no se encuentra en el PATH del sistema.")
        sys.exit(1)


def extract_audio(input_file: str, output_audio: str, quality: int = 5):
    print(f"[*] Extrayendo audio Vorbis a: {output_audio}")
    os.makedirs(os.path.dirname(os.path.abspath(output_audio)), exist_ok=True)
    cmd = [
        "ffmpeg", "-y",
        "-i", input_file,
        "-vn",
        "-acodec", "libvorbis",
        "-aq", str(quality),
        output_audio
    ]
    res = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    if res.returncode != 0:
        print(f"[!] Advertencia al extraer audio: {res.stderr}")
    else:
        print("[✓] Audio extraído con éxito.")


def extract_frames(input_file: str, temp_dir: str, fps: int = 24, width: int = 1280, height: int = 720):
    print(f"[*] Extrayendo fotogramas a {fps} fps ({width}x{height}) en directorio temporal...")
    output_pattern = os.path.join(temp_dir, "frame_%04d.png")
    vf_filter = f"fps={fps},scale={width}:{height}"
    cmd = [
        "ffmpeg", "-y",
        "-i", input_file,
        "-vf", vf_filter,
        output_pattern
    ]
    res = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    if res.returncode != 0:
        print(f"[!] Error extrayendo fotogramas: {res.stderr}")
        sys.exit(1)

    frames = sorted([f for f in os.listdir(temp_dir) if f.endswith(".png")])
    print(f"[✓] {len(frames)} fotogramas extraídos.")
    return frames


def pack_sparrow_atlas(temp_dir: str, frames: list, output_base: str, width: int = 1280, height: int = 720, max_atlas_size: int = 4096, fps: int = 24):
    print(f"[*] Empaquetando {len(frames)} fotogramas en hoja de sprites Sparrow...")

    cols = max_atlas_size // width
    rows = max_atlas_size // height
    frames_per_sheet = cols * rows

    if frames_per_sheet < 1:
        cols = 1
        rows = 1
        frames_per_sheet = 1

    total_sheets = math.ceil(len(frames) / frames_per_sheet)
    os.makedirs(os.path.dirname(os.path.abspath(output_base)), exist_ok=True)

    sheet_index = 0
    start_frame = 0

    while start_frame < len(frames):
        sheet_frames = frames[start_frame:start_frame + frames_per_sheet]
        num_frames = len(sheet_frames)

        sheet_cols = min(cols, num_frames)
        sheet_rows = math.ceil(num_frames / sheet_cols)
        sheet_w = sheet_cols * width
        sheet_h = sheet_rows * height

        atlas_img = Image.new("RGBA", (sheet_w, sheet_h), (0, 0, 0, 0))
        root_xml = ET.Element("TextureAtlas")
        sheet_filename = f"{os.path.basename(output_base)}.png" if total_sheets == 1 else f"{os.path.basename(output_base)}_{sheet_index}.png"
        root_xml.set("imagePath", sheet_filename)
        root_xml.set("fps", str(fps))

        for i, frame_name in enumerate(sheet_frames):
            frame_path = os.path.join(temp_dir, frame_name)
            col = i % sheet_cols
            row = i // sheet_cols
            x = col * width
            y = row * height

            with Image.open(frame_path) as frame_img:
                atlas_img.paste(frame_img, (x, y))

            global_frame_idx = start_frame + i
            sub = ET.SubElement(root_xml, "SubTexture")
            sub.set("name", f"cutscene{global_frame_idx:04d}")
            sub.set("x", str(x))
            sub.set("y", str(y))
            sub.set("width", str(width))
            sub.set("height", str(height))
            sub.set("frameX", "0")
            sub.set("frameY", "0")
            sub.set("frameWidth", str(width))
            sub.set("frameHeight", str(height))

        # Guardar imagen y XML
        img_out = f"{output_base}.png" if total_sheets == 1 else f"{output_base}_{sheet_index}.png"
        xml_out = f"{output_base}.xml" if total_sheets == 1 else f"{output_base}_{sheet_index}.xml"

        atlas_img.save(img_out, format="PNG", optimize=True)

        xml_str = minidom.parseString(ET.tostring(root_xml)).toprettyxml(indent="    ")
        with open(xml_out, "w", encoding="utf-8") as f:
            f.write(xml_str)

        print(f"[✓] Atlas generado: {img_out} y {xml_out}")
        sheet_index += 1
        start_frame += frames_per_sheet


def main():
    parser = argparse.ArgumentParser(description="Convertidor de cinemáticas de video para Nintendo Switch (Friday Night Funkin')")
    parser.add_argument("--input", "-i", required=True, help="Ruta al video de entrada (.mp4, .mkv, .webm)")
    parser.add_argument("--output", "-o", required=True, help="Ruta base de salida (sin extensión)")
    parser.add_argument("--fps", type=int, default=24, help="FPS de extracción de frames (por defecto: 24)")
    parser.add_argument("--width", type=int, default=1280, help="Ancho del frame en píxeles (por defecto: 1280)")
    parser.add_argument("--height", type=int, default=720, help="Alto del frame en píxeles (por defecto: 720)")
    parser.add_argument("--quality", type=int, default=5, help="Calidad de audio Vorbis de 0 a 10 (por defecto: 5)")

    args = parser.parse_args()

    check_ffmpeg()

    if not os.path.isfile(args.input):
        print(f"Error: El archivo de entrada no existe: {args.input}")
        sys.exit(1)

    output_audio = f"{args.output}.ogg"
    extract_audio(args.input, output_audio, args.quality)

    with tempfile.TemporaryDirectory() as temp_dir:
        frames = extract_frames(args.input, temp_dir, args.fps, args.width, args.height)
        pack_sparrow_atlas(temp_dir, frames, args.output, args.width, args.height, fps=args.fps)

    print("\n[✓] ¡Conversión completada con éxito!")
    print(f"    Archivos generados en: {os.path.dirname(os.path.abspath(args.output))}")


if __name__ == "__main__":
    main()
