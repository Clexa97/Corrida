# D20 Racing

Jogo de corrida por turnos baseado em um dado de 20 lados. Os jogadores entram como visitantes, criam seus corredores e disputam uma corrida online com salas, voltas, itens e ataques.

## Tecnologias

- Vite e JavaScript no frontend
- Supabase Auth para visitantes anônimos
- Supabase PostgreSQL com Row Level Security
- Supabase Realtime para sincronização das salas
- Supabase Storage para avatares
- GitHub Pages para hospedagem do frontend

## Executar localmente

Requisitos: Node.js 22 ou mais recente.

```bash
npm install
copy .env.example .env
npm run dev
```

Sem um `.env` válido, o jogo inicia automaticamente no modo local usando `localStorage`.

## Configurar o Supabase

1. Crie um projeto em [supabase.com](https://supabase.com).
2. Em **Authentication → Providers**, habilite **Anonymous Sign-Ins**.
3. Abra o **SQL Editor**.
4. Em um projeto novo, execute todos os arquivos de `supabase/migrations/` na ordem numérica.
5. Se o banco já estava configurado, execute somente as novas migrações ainda não aplicadas, também em ordem.
5. Em **Project Settings → API** ou **Connect**, copie a URL do projeto e a chave pública/publishable.
6. Crie um arquivo `.env`:

```env
VITE_SUPABASE_URL=https://SEU-PROJETO.supabase.co
VITE_SUPABASE_PUBLISHABLE_KEY=SUA_CHAVE_PUBLICA
```

Nunca coloque a chave `service_role` no `.env` do frontend ou no GitHub.

## Comandos

```bash
npm run dev       # servidor de desenvolvimento
npm run build     # build de produção em dist/
npm run preview   # visualizar o build
```

## Estrutura

```text
.
├── .github/workflows/deploy-pages.yml
├── assets/css/
├── src/
│   ├── main.js
│   ├── lib/supabase.js
│   └── services/
│       ├── auth.js
│       ├── rooms.js
│       └── storage.js
├── supabase/migrations/
├── .env.example
├── index.html
├── package.json
└── vite.config.js
```

## Segurança do jogo

O navegador não controla os resultados no modo online. As funções PostgreSQL verificam a identidade e executam de forma transacional:

- início da corrida;
- resultado do d20;
- mudança de turno;
- passagem pelos marcos 25, 50 e 75;
- sorteio e aplicação de itens;
- expiração de presentes após 60 segundos sem escolha;
- dano ao adversário;
- definição do vencedor.

As tabelas não permitem que jogadores alterem diretamente pontos, turnos ou presentes.

## Reconexão e saída

- Atualizar ou fechar a página mantém o corredor no banco.
- Ao retornar no mesmo navegador, a sessão anônima é recuperada.
- Clicar em **Sair da sala** remove explicitamente o próprio corredor.
- O anfitrião pode remover participantes ou excluir a sala.
- Quando o último corredor é removido, a sala é apagada automaticamente.
- Presentes ofensivos aparecem somente para seu proprietário; se ele não escolher um alvo em 60 segundos, o presente é perdido e o turno avança.
- Após a escolha do alvo, todas as telas exibem uma animação sincronizada com os possíveis presentes e revelam o ataque aplicado.
- A revelação pública mostra foto e nome do atacante e do corredor atingido.
- Ao final, visitantes podem voltar ao lobby ou sair; somente o anfitrião pode iniciar uma nova corrida.
- O d20 possui animação e efeitos sonoros; presentes e vitória usam sons sintetizados pelo navegador, com controle para silenciar.

## Publicar no GitHub Pages

O workflow em `.github/workflows/deploy-pages.yml` gera e publica `dist/` a cada push na `main`.

No GitHub:

1. Em **Settings → Secrets and variables → Actions**, crie:
   - `VITE_SUPABASE_URL`
   - `VITE_SUPABASE_PUBLISHABLE_KEY`
2. Em **Settings → Pages**, selecione **GitHub Actions** como fonte.
3. Faça push para a branch `main`.

O `.env` não deve ser enviado ao repositório; somente `.env.example` é versionado.
