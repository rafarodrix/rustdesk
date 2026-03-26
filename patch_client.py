import os
import sys

# Garante UTF-8 no Windows
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
        print(f"Corrigido: {file_path}")

def run_patch():
    print("--- Iniciando Super Patch Trilink ---")

    # 1. Branding e Servidor
    replace_in_file('libs/hbb_common/src/config.rs', 'rendezvous_server: "".to_owned()', f'rendezvous_server: "{SERVIDOR}".to_owned()')
    replace_in_file('libs/hbb_common/src/config.rs', 'key: "".to_owned()', f'key: "{KEY}".to_owned()')
    replace_in_file('flutter/lib/common.dart', "static const String appName = 'RustDesk';", f"static const String appName = '{NOME_DO_APP}';")
    replace_in_file('flutter/lib/common/theme.dart', 'Colors.teal', f'Color({COR_HEX_FLUTTER})')

    # 2. CORREÇÕES DE COMPATIBILIDADE (Onde o erro aconteceu)
    print("Aplicando correcoes de Null Safety e Temas...")
    
    # Erro de DialogTheme e TabBarTheme (mudança de nome no Flutter novo)
    replace_in_file('flutter/lib/common.dart', 'DialogTheme', 'DialogThemeData')
    replace_in_file('flutter/lib/common.dart', 'TabBarTheme', 'TabBarThemeData')
    
    # Erro no arquivo dialog.dart (title não pode ser nulo)
    # Trocamos 'String title' por 'String? title' para o Flutter aceitar valores nulos
    replace_in_file('flutter/lib/common/widgets/dialog.dart', 'final String title;', 'final String? title;')
    replace_in_file('flutter/lib/common/widgets/dialog.dart', 'required this.title', 'this.title')
    
    # Erro no common.dart (String? vs String)
    replace_in_file('flutter/lib/common.dart', 'String? id', 'String id')

    print("--- Super Patch Finalizado ---")

if __name__ == "__main__":
    run_patch()