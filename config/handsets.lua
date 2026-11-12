Config.Handsets = {
    phone = 'standard', -- legacy item: converted once, never stacked
    phone_standard = 'standard', phone_flip = 'flip', phone_fold = 'fold'
}
Config.SimItem = 'phone_sim'
Config.SimSwap = 'both' -- player | shop | both
-- Inserting a SIM moves its item into the phone (exactly one item leaves the inventory); removing it returns the
-- same item with its number. The inventory gateway does this; the phone re-checks it. Set false to skip the re-check.
Config.ConsumeSimOnInstall = true
Config.LaunchApps = { phone=true, contacts=true, messages=true, camera=true, gallery=true, gps=true,
    settings=true, mail=true, notes=true, calculator=true, clock=true, weather=true, music=true, store=true,
    banking=true, social=true, classifieds=true, services=true, property=true, vehicles=true, flash=true, moderation=true }
Config.PhoneServices = {
    -- Replace coordinates and business job names for your server. Place each shop where no other interaction
    -- (bank teller/ATM, inventory shop, job point) sits within a few metres, or both prompts open together.
    -- The default Circuit Mobile spot is on the Alta St pavement near Legion Square, about 25 m from the
    -- Legion Fleeca teller (149.05, -1041.3). distance is the interaction radius in metres; keep it small (2.0).
    -- Digital Den doors (Vinewood, Mirror Park, Sinner St) each get a Circuit Mobile counter. Add more entries with
    -- the same shape for other stores; every entry is registered as a target zone automatically.
    shops = {
        legion = { label='Circuit Mobile', coords={x=127.4,y=-1029.2,z=29.4}, distance=2.0,
            bucket=0, recoveryFee=500, replacementFee=100, resalePercent=50,
            prices={phone_standard=1200,phone_flip=1800,phone_fold=2400,phone_sim=100} },
        digitalDenVinewood = { label='Circuit Mobile', coords={x=-509.49,y=278.57,z=83.32}, distance=2.0,
            bucket=0, recoveryFee=500, replacementFee=100, resalePercent=50,
            prices={phone_standard=1200,phone_flip=1800,phone_fold=2400,phone_sim=100} },
        digitalDenMirrorPark = { label='Circuit Mobile', coords={x=1137.82,y=-470.77,z=66.67}, distance=2.0,
            bucket=0, recoveryFee=500, replacementFee=100, resalePercent=50,
            prices={phone_standard=1200,phone_flip=1800,phone_fold=2400,phone_sim=100} },
        digitalDenSinnerSt = { label='Circuit Mobile', coords={x=392.61,y=-831.76,z=29.29}, distance=2.0,
            bucket=0, recoveryFee=500, replacementFee=100, resalePercent=50,
            prices={phone_standard=1200,phone_flip=1800,phone_fold=2400,phone_sim=100} },
        technician = { label='Mobile Workshop', coords={x=-40.1,y=-1090.7,z=26.4}, distance=2.0,
            bucket=0, job='mechanic', grade=0, recoveryFee=500, replacementFee=100, resalePercent=50,
            prices={phone_standard=1200,phone_flip=1800,phone_fold=2400,phone_sim=100} }
    },
    wifi = {
        legion = { label='Legion Public Wi-Fi', coords={x=215.8,y=-810.1,z=30.7}, radius=70, bucket=0 },
        workshop = { label='Workshop Private', coords={x=-40.1,y=-1090.7,z=26.4}, radius=25, bucket=0,
            ownerJob='mechanic', ownerGrade=2 }
    }
}
