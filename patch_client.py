import os
import sys

# Garante que o Python use UTF-8 para evitar erros de caractere no Windows
if sys.platform == "win32":
    import codecs
    sys.stdout = codecs.getwriter("utf-8")(sys.stdout.detach())

# ================= CONFIGURAÇÕES TRILINK SOFTWARE =================
NOME_DO_APP = "Trilink Suporte Remoto"
COR_HEX_FLUTTER = "0xFF004696" # Azul Blue Jeans
SERVIDOR = "acesso.trilinksoftware.com.br"
KEY = "6FpnQH+KbbpX0qw6XxF0xqnIO0QnHImwbvQ5Lv7q6gU="
# ==================================================================

def replace_in_file(file_path, old_text, new_text):
    if os.path.exists(file_path):
        with open(file_path, 'r', encoding='utf-8') as f:
            content = f.read()
        new_content = content.replace(old_text, new_text)
        with open(file_path, 'w', encoding='utf-8') as f:
            f.write(new_content)
        # Removido o símbolo de check para evitar erro de encoding no terminal Windows
        print(f"Patch aplicado em: {file_path}")
    else:
        print(f"Arquivo nao encontrado (pulando): {file_path}")

def run_patch():
    print("--- Iniciando Patch e Auto-Fix Trilink ---")

    # 1. Configurações de Servidor e Nome
    replace_in_file('libs/hbb_common/src/config.rs', 'rendezvous_server: "".to_owned()', f'rendezvous_server: "{SERVIDOR}".to_owned()')
    replace_in_file('libs/hbb_common/src/config.rs', 'key: "".to_owned()', f'key: "{KEY}".to_owned()')
    replace_in_file('flutter/lib/common.dart', "static const String appName = 'RustDesk';", f"static const String appName = '{NOME_DO_APP}';")
    replace_in_file('flutter/lib/common/theme.dart', 'Colors.teal', f'Color({COR_HEX_FLUTTER})')

    # 2. AUTO-FIX: Corrigindo incompatibilidades de versao do Flutter (DialogTheme -> DialogThemeData)
    print("Corrigindo incompatibilidades de UI do Flutter...")
    replace_in_file('flutter/lib/common.dart', 'DialogTheme', 'DialogThemeData')
    replace_in_file('flutter/lib/common.dart', 'TabBarTheme', 'TabBarThemeData')
    replace_in_file('flutter/lib/common/widgets/dialog.dart', 'String? title', 'String title')

    print("--- Patch e correcoes aplicadas com sucesso! ---")

if __name__ == "__main__":
    run_patch()