"""Narrow entitlement decoder: dictionary of booleans, UTF-8 strings and string arrays.
Not an AMFI validator. Unsupported types, duplicate keys, bad lengths and trailing bytes reject.
ldid 2.1.5 emits a one-byte TRUE of 01; accept that observed form and ASN.1 FF only.
"""
def decode_der_entitlements(data):
    if not isinstance(data,bytes) or not 2<=len(data)<=16384:raise ValueError('DER entitlement size')
    def tlv(blob,start):
        if start+2>len(blob):raise ValueError('DER truncated header')
        tag=blob[start];first=blob[start+1];pos=start+2
        if first<128:size=first
        else:
            n=first&127
            if n==0 or n>2 or pos+n>len(blob):raise ValueError('DER indefinite/oversize length')
            raw=blob[pos:pos+n];pos+=n;size=int.from_bytes(raw,'big')
            if raw[0]==0 or size<128 or (n==2 and size<256):raise ValueError('DER nonminimal length')
        end=pos+size
        if end>len(blob):raise ValueError('DER content exceeds container')
        return tag,blob[pos:end],end
    def string(blob):
        value=blob.decode('utf-8','strict')
        if not value or len(blob)>1024 or any(ord(c)<32 or ord(c)==127 for c in value):raise ValueError('DER invalid entitlement string')
        return value
    def value(tag,blob):
        if tag==1:
            if len(blob)!=1 or blob[0] not in (0,1,255):raise ValueError('DER invalid boolean')
            return blob[0]!=0
        if tag==12:return string(blob)
        if tag==48:
            values=[];pos=0
            while pos<len(blob):
                t,b,pos=tlv(blob,pos)
                if t!=12:raise ValueError('DER array must contain only strings')
                values.append(string(b))
                if len(values)>64:raise ValueError('DER oversized array')
            return values
        raise ValueError('DER unsupported entitlement type')
    tag,body,end=tlv(data,0)
    if tag!=49 or end!=len(data):raise ValueError('DER root must be one complete set')
    result={};pos=0;previous=None
    while pos<len(body):
        start=pos;t,pair,pos=tlv(body,pos);encoded=body[start:pos]
        if t!=48 or previous is not None and encoded<=previous:raise ValueError('DER unordered/duplicate dictionary entry')
        previous=encoded;k,key,offset=tlv(pair,0)
        if k!=12:raise ValueError('DER dictionary key type')
        key=string(key)
        if key in result:raise ValueError('DER duplicate key')
        t,v,offset=tlv(pair,offset)
        if offset!=len(pair):raise ValueError('DER trailing dictionary value')
        result[key]=value(t,v)
        if len(result)>64:raise ValueError('DER oversized dictionary')
    return result
