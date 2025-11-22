import os
import subprocess
import sys
import glob

def run(cmd):
    print(f"Running: {' '.join(cmd)}")
    subprocess.check_call(cmd)

def ensure_dir(d):
    if not os.path.exists(d):
        os.makedirs(d)

def find_fxc():
    # Check if fxc is in path
    try:
        subprocess.check_call(['fxc', '/?'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return 'fxc'
    except (FileNotFoundError, subprocess.CalledProcessError):
        pass
    
    # Try common locations
    possible_paths = [
        r"C:\Program Files (x86)\Windows Kits\10\bin\10.0.22621.0\x64\fxc.exe",
        r"C:\Program Files (x86)\Windows Kits\10\bin\10.0.22000.0\x64\fxc.exe",
        r"C:\Program Files (x86)\Windows Kits\10\bin\10.0.20348.0\x64\fxc.exe",
        r"C:\Program Files (x86)\Windows Kits\10\bin\10.0.19041.0\x64\fxc.exe",
        r"C:\Program Files (x86)\Windows Kits\10\bin\x64\fxc.exe"
    ]
    for p in possible_paths:
        if os.path.exists(p):
            print(f"Found fxc at {p}")
            return p
            
    print("Error: fxc not found. Please ensure Windows SDK is installed.")
    return None

def generate_d3d_shaders(shaders_dir, out_dir):
    print(f"Generating D3D shaders from {shaders_dir} to {out_dir}")
    
    d3d_out = os.path.join(out_dir, 'd3d')
    ensure_dir(d3d_out)
    
    fxc_cmd = find_fxc()
    if not fxc_cmd:
        sys.exit(1)
        
    d3d_src_dir = os.path.join(shaders_dir, 'd3d')
    hlsl_files = glob.glob(os.path.join(d3d_src_dir, '*.hlsl'))
    
    for hlsl in hlsl_files:
        filename = os.path.basename(hlsl)
        name_no_ext = os.path.splitext(filename)[0]
        
        # Vertex Shader
        vert_out = os.path.join(d3d_out, f"{name_no_ext}.vert.h")
        # Check timestamp
        if os.path.exists(vert_out) and os.path.getmtime(vert_out) > os.path.getmtime(hlsl):
            pass # Up to date
        else:
            cmd_vert = [fxc_cmd, '/D', 'VERTEX', '/I', out_dir, '/Zi', '/T', 'vs_5_0', '/Fh', vert_out, hlsl]
            run(cmd_vert)
        
        # Fragment Shader
        if filename == 'render_atlas.hlsl':
            # render_atlas_stroke.frag.h
            stroke_out = os.path.join(d3d_out, 'render_atlas_stroke.frag.h')
            if not (os.path.exists(stroke_out) and os.path.getmtime(stroke_out) > os.path.getmtime(hlsl)):
                cmd_stroke = [fxc_cmd, '/D', 'FRAGMENT', '/D', 'ATLAS_FEATHERED_STROKE', '/Zi', '/I', out_dir, '/T', 'ps_5_0', '/Fh', stroke_out, hlsl]
                run(cmd_stroke)
            
            # render_atlas_fill.frag.h
            fill_out = os.path.join(d3d_out, 'render_atlas_fill.frag.h')
            if not (os.path.exists(fill_out) and os.path.getmtime(fill_out) > os.path.getmtime(hlsl)):
                cmd_fill = [fxc_cmd, '/D', 'FRAGMENT', '/D', 'ATLAS_FEATHERED_FILL', '/Zi', '/I', out_dir, '/T', 'ps_5_0', '/Fh', fill_out, hlsl]
                run(cmd_fill)
        else:
            frag_out = os.path.join(d3d_out, f"{name_no_ext}.frag.h")
            if not (os.path.exists(frag_out) and os.path.getmtime(frag_out) > os.path.getmtime(hlsl)):
                cmd_frag = [fxc_cmd, '/D', 'FRAGMENT', '/I', out_dir, '/Zi', '/T', 'ps_5_0', '/Fh', frag_out, hlsl]
                run(cmd_frag)

    # Root Signature
    root_sig_src = os.path.join(d3d_src_dir, 'root.sig')
    if os.path.exists(root_sig_src):
        root_sig_out = os.path.join(d3d_out, 'root.sig.h')
        if not (os.path.exists(root_sig_out) and os.path.getmtime(root_sig_out) > os.path.getmtime(root_sig_src)):
            cmd_sig = [fxc_cmd, '/I', out_dir, '/T', 'rootsig_1_1', '/E', 'ROOT_SIG', '/Fh', root_sig_out, root_sig_src]
            run(cmd_sig)

def main():
    if len(sys.argv) < 3:
        print("Usage: generate_shaders.py <shaders_dir> <out_dir>")
        sys.exit(1)
        
    shaders_dir = sys.argv[1]
    out_dir = sys.argv[2]
    
    ensure_dir(out_dir)
    
    # 1. Minify
    print("--- Minifying Shaders ---")
    minify_script = os.path.join(shaders_dir, "minify.py")
    inputs = glob.glob(os.path.join(shaders_dir, "*.glsl")) + \
             glob.glob(os.path.join(shaders_dir, "*.vert")) + \
             glob.glob(os.path.join(shaders_dir, "*.frag"))
    
    cmd = [sys.executable, minify_script, '-o', out_dir] + inputs
    run(cmd)
    
    # 2. Generate D3D Shaders
    generate_d3d_shaders(shaders_dir, out_dir)

if __name__ == "__main__":
    main()
