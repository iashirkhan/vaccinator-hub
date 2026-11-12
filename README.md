# Vaccinator Resource Hub

A web app for vaccinators: a library of documents and job aids, step-by-step training modules with progress tracking, and an assistant that answers questions from your uploaded PDFs.

It runs on three free or pay-as-you-go services:

| Service | What it does | Cost |
|---|---|---|
| **GitHub Pages** | Hosts the website and gives you the link to share | Free |
| **Supabase** | Accounts and sign-in, the database, and file storage | Free plan: 500 MB database, 1 GB files |
| **Anthropic (Claude API)** | Powers the Ask assistant | Pay per use. See [Costs](#costs) |

What's in this folder:

```
index.html                      the web app
config.js                       your Supabase address and key (you fill this in)
supabase/setup.sql              creates the database tables and security rules
supabase/functions/ask/index.ts the assistant (runs on Supabase, keeps your API key secret)
```

Setup takes about 30–45 minutes. Do the steps in order.

---

## Step 1. Create a GitHub account

1. Go to **https://github.com/signup**.
2. Enter your email, a password and a username. Your username becomes part of your link (`https://USERNAME.github.io/...`), so pick something short.
3. Verify your email when GitHub asks.

## Step 2. Create the repository and upload the files

1. Signed in to GitHub, click **+** (top right) → **New repository**.
2. **Repository name:** `vaccinator-hub` (or any name without spaces).
3. Choose **Public**. Free GitHub Pages needs a public repository. Only the app's code is public. Your documents, accounts and progress live in Supabase, behind sign-in.
4. Tick **Add a README file**, then click **Create repository**.
5. On the repository page, click **Add file** → **Upload files**.
6. Drag in **everything in this folder**: `index.html`, `config.js`, `README.md`, and the whole `supabase` folder. (Drag the folder itself so its structure is kept. This works in Chrome and Edge.)
7. Scroll down and click **Commit changes**.

## Step 3. Turn on GitHub Pages (this creates your link)

1. In the repository, click **Settings** → **Pages** (left menu).
2. Under **Build and deployment** → **Source**, choose **Deploy from a branch**.
3. Under **Branch**, choose **main** and **/ (root)**, then click **Save**.
4. Wait 1–2 minutes and refresh. The page shows **"Your site is live at https://USERNAME.github.io/vaccinator-hub/"**. That's the link you'll share. Copy it; you need it in step 5.

If you open it now you'll see "This hub isn't connected yet". That's expected until step 6.

## Step 4. Create the Supabase project and database

1. Go to **https://supabase.com** → **Start your project** → **Continue with GitHub**.
2. Click **New project**.
   - **Name:** `vaccinator-hub`
   - **Database password:** click **Generate a password** and save it somewhere safe.
   - **Region:** pick the one closest to your vaccinators (for example *South Asia (Mumbai)*).
   - Plan: **Free**. Click **Create new project** and wait about 2 minutes.
3. In the left menu, open **SQL Editor** → **New query**.
4. Open `supabase/setup.sql` from this folder, copy all of it, paste it into the editor, and click **Run**. You should see "Success. No rows returned".

## Step 5. Set up sign-in

1. In Supabase, open **Authentication** → **URL Configuration**.
   - **Site URL:** paste your GitHub Pages link from step 3 (for example `https://USERNAME.github.io/vaccinator-hub/`).
   - Under **Redirect URLs**, click **Add URL** and paste the same link. Save.
2. Open **Authentication** → **Sign In / Providers** → **Email**.
   - Turn **Confirm email** **off**, then save. *Recommended:* Supabase's free plan can only send a few emails per hour, so confirmation emails would block people from joining. With it off, people can sign in as soon as they create an account.
   - "Forgot password" emails still work, within that hourly email limit.

## Step 6. Connect the website to Supabase

1. In Supabase, open **Project Settings** (gear icon) → **API** (in newer dashboards: **Data API** for the URL and **API Keys** for the key).
2. Copy the **Project URL** (looks like `https://abcdefgh.supabase.co`).
3. Copy the **anon public** key (or the **Publishable key**, which starts with `sb_publishable_`). **Don't use** the `service_role` or **Secret** key. That one must never go on the website.
4. In GitHub, open your repository → click **config.js** → click the **pencil icon** (Edit).
5. Replace the two placeholder values with what you copied:

   ```js
   window.HUB_CONFIG = {
     SUPABASE_URL: "https://abcdefgh.supabase.co",
     SUPABASE_ANON_KEY: "eyJhbGciOi...your key..."
   };
   ```

6. Click **Commit changes** → **Commit changes**. GitHub republishes the site within a minute or two.

## Step 7. Get a Claude API key (for the Ask assistant)

1. Go to **https://console.anthropic.com** and create an account.
2. Open **Billing** and add credit (for example US $10–20 to start). Set a monthly spending limit under **Limits** so you're never surprised.
3. Open **API Keys** → **Create Key**, name it `vaccinator-hub`, and copy the key (it starts with `sk-ant-`). You only see it once.

**Never put this key in GitHub or config.js.** It goes into Supabase in the next step, where nobody can see it.

## Step 8. Deploy the assistant

1. In Supabase, open **Edge Functions** → **Deploy a new function** → **Via Editor**.
2. Name the function exactly **`ask`**.
3. Delete the sample code, then open `supabase/functions/ask/index.ts` from this folder, copy all of it and paste it in.
4. Click **Deploy function**.
5. Go to **Edge Functions** → **Secrets** (or **Manage secrets**). Add a secret:
   - **Name:** `ANTHROPIC_API_KEY`
   - **Value:** the `sk-ant-...` key from step 7
   - Click **Save**.

## Step 9. Create your account first (this makes you the editor)

1. Open your link from step 3.
2. Click **Create an account**, then enter your name, email and a password.
3. **The first account created becomes the editor.** Everyone who signs up after you is a vaccinator. Do this before you share the link.
4. You'll see a **Manage** tab. Upload a PDF, then try the **Ask** tab and the example module in **Training**.

## Step 10. Share the link

Send your GitHub Pages link to your vaccinators. Each person clicks **Create an account**, then they can:

- browse and open everything in the **Library**
- work through **Training** modules, with their own progress saved
- ask the **Ask** assistant questions (up to 40 per person per day)

To make a supervisor an editor too: **Manage** → **People** → change their role to **Editor**.

---

## Costs

- **GitHub Pages:** free.
- **Supabase free plan:** free. Note that free projects **pause after 7 days with no activity**. If that happens, open supabase.com and click **Restore project**. The paid plan (US $25/month) never pauses.
- **Claude API:** the assistant uses Claude Opus 5.5, Anthropic's current default model. Each question runs a few searches, so a typical answer costs roughly **US 5–20 cents**, depending on how much text it reads. That's an estimate, so check **Usage** in the Anthropic console after a week. To cut costs a lot, open `supabase/functions/ask/index.ts` in Supabase, change `const MODEL = "claude-opus-5-5";` to `"claude-haiku-5-5"`, and redeploy. Answers will be less thorough.
- To change the daily question limit, edit `DAILY_LIMIT` in the same file.

## Updating the app later

- **Documents, training modules and people** are all managed inside the app (Manage and Training tabs). No GitHub changes needed.
- **Changing the app itself:** edit `index.html` on GitHub (pencil icon) and commit. The site updates within a couple of minutes.

## Troubleshooting

| Problem | Fix |
|---|---|
| "This hub isn't connected yet" | `config.js` still has the placeholders (step 6). |
| Can't sign in after creating an account | Turn off **Confirm email** (step 5), or click the link in the confirmation email. |
| Forgot-password link opens the wrong page | Check **Site URL** and **Redirect URLs** (step 5). |
| No **Manage** tab | You're not an editor. In Supabase → **Table Editor** → `profiles`, set your `role` to `editor`. |
| Ask says "couldn't be reached" | The function isn't deployed or isn't named `ask` (step 8). |
| Ask says the API key was rejected | Check the `ANTHROPIC_API_KEY` secret (step 8) and that your Anthropic account has credit. |
| A PDF shows "No readable text" | It's a scanned image. Run it through OCR (for example, Adobe Acrobat → *Scan & OCR*) and upload it again using **Replace file**. |
| Everything stopped working after a quiet week | The free Supabase project paused. Restore it on supabase.com. |
