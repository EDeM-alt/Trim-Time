const { createClient } = require('@supabase/supabase-js');
const crypto = require('crypto');
module.exports = async (req, res) => {
  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });
  try {
    const token = (req.headers.authorization || '').replace(/^Bearer\s+/i, '');
    if (!token) return res.status(401).json({ error: 'Sign in is required.' });
    const supabase = createClient(process.env.SUPABASE_URL, process.env.SUPABASE_SERVICE_ROLE_KEY);
    const { data: { user }, error: authError } = await supabase.auth.getUser(token);
    if (authError || !user) return res.status(401).json({ error: 'Your session is invalid. Please sign in again.' });
    const { appointmentId, callbackUrl } = req.body || {};
    if (!appointmentId) return res.status(400).json({ error: 'appointmentId is required.' });
    const { data: appointment, error } = await supabase.from('appointments').select('id,customer_id,status,quoted_price_ghs,services(name),shops(name)').eq('id', appointmentId).single();
    if (error || !appointment) return res.status(404).json({ error: 'Appointment not found.' });
    if (appointment.customer_id !== user.id) return res.status(403).json({ error: 'You cannot pay for another customer’s appointment.' });
    if (appointment.status !== 'pending_payment') return res.status(409).json({ error: 'This appointment is not awaiting payment.' });
    const amount = Math.round(Number(appointment.quoted_price_ghs) * 100);
    if (!Number.isFinite(amount) || amount < 100) return res.status(400).json({ error: 'The appointment amount must be at least GH₵1.00.' });
    const reference = `TT-${appointment.id.replace(/-/g,'').slice(0,18)}-${crypto.randomBytes(4).toString('hex')}`;
    const { error: insertError } = await supabase.from('payments').insert({ appointment_id: appointment.id, customer_id: user.id, provider: 'paystack', reference, amount_ghs: amount / 100, status: 'initialized' });
    if (insertError) throw insertError;
    const response = await fetch('https://api.paystack.co/transaction/initialize', {
      method: 'POST', headers: { Authorization: `Bearer ${process.env.PAYSTACK_SECRET_KEY}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ email: user.email, amount, currency: 'GHS', reference, callback_url: callbackUrl || `${process.env.PUBLIC_SITE_URL}/payment-return.html`, metadata: { appointment_id: appointment.id, customer_id: user.id, service: appointment.services?.name || 'TrimTime service', shop: appointment.shops?.name || 'TrimTime partner' } })
    });
    const result = await response.json();
    if (!response.ok || !result.status) throw new Error(result.message || 'Could not start payment.');
    await supabase.from('payments').update({ status: 'pending', provider_reference: result.data?.reference || reference }).eq('reference', reference);
    return res.status(200).json({ authorization_url: result.data.authorization_url, reference });
  } catch (e) { console.error('Paystack initialize error:', e.message); return res.status(500).json({ error: 'Payment could not be started. Please try again or contact TrimTime.' }); }
};
