import os

# ================= CONFIGURAÇÕES TRILINK SOFTWARE =================
# Dados do Branding
NOME_DO_APP = "Suporte Trilink"
# Sua cor primária convertida de CMYK para Flutter Hex (Azul Blue Jeans)
COR_HEX_FLUTTER = "0xFF004696" 

# Dados do Servidor Hospedado (Hardcode)
SERVIDOR = "acesso.trilinksoftware.com.br"
KEY = "6FpnQH+KbbpX0qw6XxF0xqnIO0QnHImwbvQ5Lv7q6gU="
# ==================================================================

def replace_in_file(file_path, old_text, new_text):
    if os.path.exists(file_path):
        try:
            with open(file_path, 'r', encoding='utf-8') as f:
                content = f.read()
            new_content = content.replace(old_text, new_text)
            with open(file_path, 'w', encoding='utf-8') as f:
                f.write(new_content)
            print(f"✓ {file_path}")
        except Exception as e:
            print(f"Error patching {file_path}: {e}")
    else:
        # Muitas vezes o arquivo não existe em certas versões, é normal.
        pass

def run_patch():
    print(f"--- Iniciando Patch Trilink Software ---")
    print(f"App Name: {NOME_DO_APP}")
    print(f"Cor: {COR_HEX_FLUTTER}")

    # 1. Configuração do Servidor (Rust Core - libs/hbb_common/src/config.rs)
    # Procuramos os locais padrão vazios e substituímos
    replace_in_file('libs/hbb_common/src/config.rs', 'rendezvous_server: "".to_owned()', f'rendezvous_server: "{SERVIDOR}".to_owned()')
    replace_in_file('libs/hbb_common/src/config.rs', 'relay_server: "".to_owned()', f'relay_server: "{SERVIDOR}".to_owned()')
    replace_in_file('libs/hbb_common/src/config.rs', 'api_server: "".to_owned()', f'api_server: "{SERVIDOR}".to_owned()')
    replace_in_file('libs/hbb_common/src/config.rs', 'key: "".to_owned()', f'key: "{KEY}".to_owned()')

    # 2. Configuração do Nome do App (Android Mandatório)
    replace_in_file('android/app/src/main/AndroidManifest.xml', 'android:label="RustDesk"', f'android:label="{NOME_DO_APP}"')

    # 3. Nome do App no Flutter (Interface Principal)
    # Procuramos o appName definido no common.dart
    replace_in_file('flutter/lib/common.dart', "static const String appName = 'RustDesk';", f"static const String appName = '{NOME_DO_APP}';")
    
    # 4. Tema e Cores no Flutter
    # Procuramos a cor padrão 'teal' (comum no RustDesk) e trocamos pela sua.
    # Esta linha pode precisar de ajustes dependendo da versão exata do fork.
    replace_in_file('flutter/lib/common/theme.dart', 'Colors.teal', f'Color({COR_HEX_FLUTTER})')

    print("\n--- Patch Trilink Aplicado com Sucesso! ---")

if __name__ == "__main__":
    run_patch()