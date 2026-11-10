const fs = require('node:fs');
const { randomBytes, randomInt } = require('node:crypto');

// The UI owns this file after first boot; never replace pairing or plugin data.
if (!fs.existsSync('config.json')) {
  let pin;
  do {
    pin = String(randomInt(10000000, 100000000));
  } while (/^(\d)\1{7}$/.test(pin) || ['12345678', '87654321'].includes(pin));

  const config = {
    bridge: {
      name: 'Homebridge',
      username: `0E:${randomBytes(5).toString('hex').match(/../g).join(':').toUpperCase()}`,
      pin: `${pin.slice(0, 3)}-${pin.slice(3, 5)}-${pin.slice(5)}`,
      port: 51826,
      advertiser: 'ciao',
      bind: [process.env.HOMEBRIDGE_BIND],
    },
    accessories: [],
    platforms: [{ name: 'Config', platform: 'config', port: 8581 }],
  };

  // Publish only complete JSON; an interrupted write must not reset pairing.
  fs.writeFileSync('config.json.tmp', JSON.stringify(config, null, 2), { mode: 0o600 });
  fs.renameSync('config.json.tmp', 'config.json');
}
