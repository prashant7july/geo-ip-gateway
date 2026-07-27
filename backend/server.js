// Stand-in for your Node.js microservices. This never sees a request that
// the gateway's access_control.lua rejected — that's the whole point.
const express = require('express');
const app = express();

app.get('/', (req, res) => {
  res.json({
    message: 'Hello — you passed the gateway access-control checks.',
    seen_headers: {
      'x-real-ip': req.headers['x-real-ip'],
      'x-forwarded-for': req.headers['x-forwarded-for'],
    },
  });
});

app.listen(3000, () => console.log('backend listening on :3000'));
