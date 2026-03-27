import os
import sys

if sys.platform == "win32":
    import codecs
    sys.stdout = codecs.getwriter("utf-8")(sys.stdout.detach())

# ================= CONFIGURAÇÕES TRILINK =================
NOME_DO_APP = "Trilink Suporte Remoto"
COR_HEX_FLUTTER = "0xFF004696"
SERVIDOR = "acesso.trilinksoftware.com.br"
KEY = "6FpnQH+KbbpX0qw6XxF0xqnIO0QnHImwbvQ5Lv7q6gU="
# =========================================================

def replace_in_file(file_path, old_text, new_text):
    if os.path.exists(file_path):
        with open(file_path, 'r', encoding='utf-8') as f:
            content = f.read()
        new_content = content.replace(old_text, new_text)
        with open(file_path, 'w', encoding='utf-8') as f:
            f.write(new_content)
        print(f"Aplicado: {file_path}")

def run_patch():
    print("--- Iniciando Patch Trilink v6.0 ---")

    # 1. Configurações de Servidor (Rust)
    replace_in_file('libs/hbb_common/src/config.rs', 'rendezvous_server: "".to_owned()', f'rendezvous_server: "{SERVIDOR}".to_owned()')
    replace_in_file('libs/hbb_common/src/config.rs', 'key: "".to_owned()', f'key: "{KEY}".to_owned()')

    # 2. Branding (Flutter)
    # Patch no nome do app
    replace_in_file('flutter/lib/common.dart', "static const String appName = 'RustDesk';", f"static const String appName = '{NOME_DO_APP}';")
    # Patch na cor principal
    replace_in_file('flutter/lib/common/theme.dart', 'Colors.teal', f'Color({COR_HEX_FLUTTER})')

    print("--- Patch v6.0 Finalizado com Sucesso ---")

if __name__ == "__main__":
    run_patch()