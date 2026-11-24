const { createClient } = require('@supabase/supabase-js');
const crypto = require('crypto');
module.exports = async (req, res) => {
  if (req.method !== 'POST') return res.status(405).send('Method not allowed');
  try {
    let raw;
    if (req.rawBody) raw = Buffer.from(req.rawBody);
    else { const chunks=[]; for await (const chunk of req) chunks.push(Buffer.from(chunk)); raw=Buffer.concat(chunks); }
    const signature = req.headers['x-paystack-signature'];
    const expected = crypto.createHmac('sha512', process.env.PAYSTACK_SECRET_KEY).update(raw).digest('hex');
    const supplied = Buffer.from(String(signature || '')); const expectedBuffer = Buffer.from(expected);
    if (!signature || supplied.length !== expectedBuffer.length || !crypto.timingSafeEqual(supplied, expectedBuffer)) return res.status(401).send('Invalid signature');
    const event = JSON.parse(raw.toString('utf8'));
    if (event.event !== 'charge.success') return res.status(200).send('Event ignored');
    const ref = event.data?.reference;
    if (!ref) return res.status(400).send('Missing reference');
    // Verify the transaction directly with Paystack before updating the booking.
    const verifyResponse = await fetch(`https://api.paystack.co/transaction/verify/${encodeURIComponent(ref)}`, { headers: { Authorization: `Bearer ${process.env.PAYSTACK_SECRET_KEY}` } });
    const verified = await verifyResponse.json();
    if (!verifyResponse.ok || !verified.status || verified.data?.status !== 'success') return res.status(400).send('Payment not verified');
    const supabase = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY);
    const { data: payment, error } = await supabase.from('payments').select('id,appointment_id,amount_ghs,status').eq('reference', ref).single();
    if (error || !payment) return res.status(404).send('Payment reference not found');
    const verifiedAmount = Number(verified.data.amount) / 100;
    if (Math.round(verifiedAmount * 100) !== Math.round(Number(payment.amount_ghs) * 100) || verified.data.currency !== 'GHS') return res.status(400).send('Amount or currency mismatch');
    if (payment.status === 'success') return res.status(200).send('Already processed');
    await supabase.from('payments').update({ status: 'success', paid_at: new Date().toISOString(), provider_reference: String(verified.data.id) }).eq('id', payment.id);
    await supabase.from('appointments').update({ status: 'pending_confirmation' }).eq('id', payment.appointment_id).eq('status', 'pending_payment');
    return res.status(200).send('Payment recorded');
  } catch (e) { console.error('Paystack webhook error:', e.message); return res.status(500).send('Webhook processing failed'); }
};

module.exports.config = { api: { bodyParser: false } };
