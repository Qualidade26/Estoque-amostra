# Inventário de Amostra — Labor

Sistema de contagem de inventário por **SKU + lote**, com login. Ele tem dois perfis: **Administrador** e **Contagem**.

## Arquivos

- `index.html`: o sistema completo, num arquivo só (já com o logo e o fundo da Labor).
- `supabase_inventario.sql`: o script do banco de dados.

## 1. Criar o banco (Supabase)

1. Crie um projeto novo no Supabase (ex.: `inventario-amostra`).
2. Vá em **SQL Editor → New query**, cole todo o `supabase_inventario.sql` e clique em **Run**.
3. O script já cria a administradora de teste: usuário **nataly**, senha **123456**. Depois de entrar, troque a senha em **Alterar senha**.
4. Em **Project Settings → API**, copie a **Project URL** e a chave **anon / publishable**.

## 2. Ligar o sistema ao banco

Abra o `index.html` num editor de texto (ou direto no GitHub, no lápis ✏️). No começo do arquivo, no bloco `INV_CONFIG`, troque estas duas linhas:

```js
supabaseUrl: 'https://SEU-PROJETO.supabase.co',
supabaseKey: 'SUA-CHAVE-ANON-OU-PUBLISHABLE',
```

## 3. Publicar no GitHub Pages

1. Crie um repositório (ex.: `Qualidade26/Inventario-Amostra`) e envie o `index.html` (**Add file → Upload files → Commit**).
2. Vá em **Settings → Pages → Branch: main / (root) → Save**.
3. Em 1 ou 2 minutos aparece o link (ex.: `https://qualidade26.github.io/Inventario-Amostra/`).

## 4. Usar

**Administrador** (entra com o usuário `nataly`):

1. **Usuários:** cadastre quem vai contar (nome, usuário, senha e perfil **Contagem**).
2. **Base de dados:** suba o relatório de **Saldos por Lote** exportado do sistema (.xml). Também aceita Excel, .csv, .txt ou colado do Excel. O sistema lê sozinho Produto, Lote, Armazém, Saldo, Empenho, Data, Validade e Fabricação. Ele ignora os cabeçalhos repetidos de cada página, deixa entrar só o **armazém 11 – AMOSTRAS** e, por padrão, deixa de fora os lotes com saldo zero. Clique em **Salvar como base de dados**.
   - Como esse relatório não traz a descrição, use o **Cadastro de descrições**: suba uma vez um relatório que tenha a coluna Descrição (por exemplo, o de saldo com Descricao) e o sistema guarda as descrições. Os SKUs que faltarem podem ser digitados ali mesmo.
3. **Abrir inventário:** escolha **Geral** (todos os lotes da base) ou **Selecionar itens** (inventário parcial: busque e marque os lotes, marque todos os lotes de um SKU ou cole uma lista de SKUs). Dê o nome e clique em **Abrir inventário**. No inventário parcial, quem conta só consegue lançar os SKUs selecionados. O inventário guarda uma cópia da base como histórico para comparar, e a contagem fica liberada.
4. **Início:** acompanhe em tempo real o que foi contado, quem contou e as divergências. Quando a 1ª contagem terminar, clique em **Encerrar 1ª contagem e liberar recontagem**. Só os itens divergentes vão para a 2ª contagem (e depois para a 3ª e a 4ª, se precisar).
5. **Relatório:** mostra o confronto colorido de cada SKU/lote com o sistema:
   - verde: bate com o sistema
   - vermelho: falta
   - azul: sobra
   - laranja: em recontagem
6. **Exportar:** finalize o inventário e baixe a planilha em Excel. Ela tem as abas Rosto, Contagem (colorida), Lançamentos e Estatística.

**Contagem** (no celular ou no coletor):

1. Digite ou bipe o **SKU**. A descrição aparece logo abaixo.
2. Informe o **lote**, a **validade ou a fabricação** e a **quantidade**.
3. Confira o resumo do lançamento e toque em **Confirmar e salvar**.

Quem conta tem as abas **Início** (andamento da contagem, os próprios lançamentos e a lista do que recontar) e **Contagem**. Essa pessoa não vê quantidade do sistema, contagens de outras pessoas nem relatórios. Também **não pode excluir lançamentos**: se lançar errado, precisa avisar o administrador.

**Correções (só o administrador)**, no Relatório, clicando no item:
- **Excluir lançamento:** o lançamento fica no histórico como *cancelado* e a contagem do item é refeita.
- **Reabrir contagem do item:** cancela os lançamentos do item na contagem atual, e o item volta para a lista de quem conta para ser contado de novo.

## Regras (iguais às da planilha)

- **1ª contagem igual ao sistema:** OK.
- **1ª contagem diferente do sistema:** vai para a 2ª contagem.
- **O lote só fecha quando duas contagens seguidas concordam entre si** (2ª = 1ª, ou 3ª = 2ª). Se a 2ª bater com o sistema mas não com a 1ª, o item vai para a 3ª. Se a 3ª não bater com a 2ª, vai para a 4ª, que é a final.
- **SKU + lote lançado mais de uma vez na mesma contagem** (achado em lugares diferentes): as quantidades são somadas.
- **SKU/lote que não está no relatório:** entra como **item não listado**, com sistema = 0.
- **Ao encerrar a 1ª contagem:** o que ninguém lançou fica como **não encontrado (0)**.
