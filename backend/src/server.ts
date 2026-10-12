// Starts the Lofer backend:  npm start   (reads backend/.env when it exists)
import { createApp } from './app.ts';
import { createProvider } from './providers/index.ts';
import { limitsFromEnv } from './security/rateLimit.ts';
import { createVoiceProvider } from './voice/index.ts';

const port = Number(process.env.PORT ?? 8787);
// 127.0.0.1 = only this Mac (the simulator). To test on a phone on the same Wi-Fi, set HOST=0.0.0.0.
const host = process.env.HOST ?? '127.0.0.1';
const provider = createProvider();
const voice = createVoiceProvider();
const clientKey = process.env.LOFER_CLIENT_KEY || undefined;

// Real speech services cost money per request, so they are never served without client authentication.
if (voice && voice.name !== 'mock' && !clientKey) {
  throw new Error(`VOICE_PROVIDER=${voice.name} needs LOFER_CLIENT_KEY in backend/.env (and the same key in the app's scheme).`);
}

createApp(provider, { voice, clientKey, limits: limitsFromEnv() }).listen(port, host, () => {
  const model = 'model' in provider ? ` · model ${String((provider as { model: string }).model)}` : '';
  console.log(`Lofer backend on http://${host}:${port}  (Care Intelligence provider: ${provider.name}${model} · voice: ${voice?.name ?? 'off'}` +
              ` · client key ${clientKey ? 'required' : 'NOT required'})`);
});
