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
