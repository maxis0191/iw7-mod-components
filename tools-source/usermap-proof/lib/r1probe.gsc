r1_hintprobe( n )
{
    e = spawn( "script_model", ( 0, 0, 0 ) );
    e makeusable();
    for ( i = 0; i < n; i++ )
    {
        e sethintstring( "R1 PROBE HINT NUMBER " + i );
        print( "[IWZ local] GL PROBE name=hint_progress done=" + ( i + 1 ) );
        wait 0.05;
    }
    print( "[IWZ local] GL PROBE name=hint70 done=" + n );
}

r1_alive()
{
    wait 1;
    print( "[IWZ local] GL PROBE name=after alive=1" );
}

r1_stock_hints()
{
    e = spawn( "script_model", ( 0, 0, 0 ) );
    e makeusable();
    e sethintstring( &"COOP_PERK_MACHINES_1000" );
    wait 0.1;
    e sethintstring( &"CP_ZMB_INTERACTIONS_BUY_WEAPON" );
    wait 0.1;
    print( "[IWZ local] GL PROBE name=stock done=2" );
}

r1_dvar()
{
    print( "[IWZ local] GL PROBE name=dvar value=" + getdvarint( "paris_usermap_hint_filter", 99 ) );
}

r1_f( x )
{
    if ( !isdefined( x ) )
        return "u";
    return "" + x;
}

r1_perkstate()
{
    wait 2;
    names = [ "perk_machine_tough", "perk_machine_revive", "perk_machine_run" ];
    print( "[IWZ local] GL PROBE name=ps_top ints=" + r1_f( isdefined( level.interactions ) ) + " all=" + r1_f( isdefined( level.all_interaction_structs ) ) );
    foreach ( n in names )
    {
        i = level.interactions[n];
        s = scripts\engine\utility::getstructarray( n, "script_noteworthy" );
        line = "[IWZ local] GL PROBE name=ps_" + n + " idef=" + r1_f( isdefined( i ) ) + " structs=" + s.size;
        if ( isdefined( i ) )
            line += " cost=" + r1_f( i.cost ) + " canuse=" + r1_f( isdefined( i.can_use_override_func ) ) + " init=" + r1_f( isdefined( i.init_func ) ) + " reqp=" + r1_f( i.requires_power );
        if ( s.size > 0 )
            line += " s0_reqp=" + r1_f( s[0].requires_power ) + " s0_area=" + r1_f( s[0].power_area ) + " s0_on=" + r1_f( s[0].powered_on );
        print( line );
    }
    print( "[IWZ local] GL PROBE name=ps_flags power=" + r1_f( scripts\engine\utility::flag( "power_on" ) ) );
}

r1_volstate()
{
    wait 8;
    vols = getentarray( "spawn_volume", "targetname" );
    nb = 0;
    hit = "";
    s = scripts\engine\utility::getstructarray( "perk_machine_tough", "script_noteworthy" );
    foreach ( v in vols )
    {
        if ( isdefined( v.basename ) )
            nb++;
        if ( s.size > 0 && ispointinvolume( s[0].origin, v ) )
            hit += r1_f( v.basename ) + "/" + r1_f( v.script_linkname ) + ",";
    }
    print( "[IWZ local] GL PROBE name=vs vols=" + vols.size + " withbase=" + nb + " hit=" + hit + " svdone=" + r1_f( scripts\engine\utility::flag( "init_spawn_volumes_done" ) ) + " org=" + r1_f( s[0].origin ) );
}

r1_volgeo()
{
    wait 8;
    vols = getentarray( "spawn_volume", "targetname" );
    foreach ( v in vols )
    {
        o = v.origin;
        print( "[IWZ local] GL PROBE name=vg_" + r1_f( v.basename ) + " org=" + r1_f( o ) + " cls=" + r1_f( v.classname ) + " mdl=" + r1_f( v.model ) + " self=" + r1_f( ispointinvolume( o, v ) ) + " up=" + r1_f( ispointinvolume( o + ( 0, 0, 24 ), v ) ) + " ent=" + r1_f( v getentitynumber() ) );
    }
}

r1_ext( v, axis )
{
    d = [ ( 1, 0, 0 ), ( 0, 1, 0 ), ( 0, 0, 1 ) ];
    best_p = 0;
    best_n = 0;
    for ( k = 1; k <= 60; k++ )
    {
        if ( ispointinvolume( v.origin + d[axis] * ( k * 32 ), v ) )
            best_p = k * 32;
        if ( ispointinvolume( v.origin - d[axis] * ( k * 32 ), v ) )
            best_n = k * 32;
    }
    return best_p + "/" + best_n;
}

r1_volext()
{
    wait 8;
    vols = getentarray( "spawn_volume", "targetname" );
    foreach ( v in vols )
        print( "[IWZ local] GL PROBE name=ve_" + r1_f( v.basename ) + " x=" + r1_ext( v, 0 ) + " y=" + r1_ext( v, 1 ) + " z=" + r1_ext( v, 2 ) );
}

r1_nav()
{
    wait 6;
    dest = getclosestpointonnavmesh( ( -528, 3880, 0 ) );
    pts = [ ( 336, 3300, 8 ), ( -1136, 3480, 8 ), ( -400, 4300, 320 ), ( 262.875, 3300, 0.1 ), ( -1062.87, 3480, 0.1 ), ( -402.4, 4254, 0.1 ) ];
    i = 0;
    foreach ( p in pts )
    {
        s = getclosestpointonnavmesh( p );
        d = -2;
        if ( isdefined( s ) && isdefined( dest ) )
            d = getpathdist( s, dest, 20000 );
        print( "[IWZ local] GL PROBE name=nv" + i + " p=" + r1_f( p ) + " snap=" + r1_f( s ) + " dest=" + r1_f( dest ) + " pathdist=" + r1_f( d ) + " d3=" + r1_f( distance( p, dest ) ) );
        i++;
    }
}
