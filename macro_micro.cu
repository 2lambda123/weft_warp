#include <cuda.h>
#include <stdio.h>
#include "datadef.h"
#include "warp_device.cuh"

__global__ void macro_micro_kernel(unsigned N, unsigned n_materials, unsigned n_tallies, cross_section_data* d_xsdata, particle_data* d_particles, tally_data* d_tally, unsigned* d_remap, float* d_number_density_matrix){


	int tid_in = threadIdx.x+blockIdx.x*blockDim.x; 
	if (tid_in >= N){return;}

	// declare shared variables
	__shared__ 	unsigned			n_isotopes;				
	//__shared__ 	unsigned			energy_grid_len;		
	__shared__ 	unsigned			total_reaction_channels;
	__shared__ 	unsigned*			rxn_numbers;			
	__shared__ 	unsigned*			rxn_numbers_total;		
	__shared__ 	float*				energy_grid;			
	__shared__ 	float*				rxn_Q;						
	__shared__ 	float*				xs;						
	//__shared__ 	float*				awr;					
	//__shared__ 	float*				temp;					
	//__shared__ 	dist_container*		dist_scatter;			
	//__shared__ 	dist_container*		dist_energy; 
	__shared__	spatial_data*		space;	
	__shared__	unsigned*			rxn;	
	__shared__	float*				E;		
	__shared__	float*				Q;		
	__shared__	unsigned*			rn_bank;
	__shared__	unsigned*			cellnum;
	__shared__	unsigned*			matnum;	
	__shared__	unsigned*			isonum;	
	__shared__	int*				talnum;
	//__shared__	unsigned*			yield;	
	__shared__	float*				weight;	
	__shared__	unsigned*			index;	

	// have thread 0 of block copy all pointers and static info into shared memory
	if (threadIdx.x == 0){
		n_isotopes					= d_xsdata[0].n_isotopes;								
		//energy_grid_len				= d_xsdata[0].energy_grid_len;				
		total_reaction_channels		= d_xsdata[0].total_reaction_channels;
		rxn_numbers 				= d_xsdata[0].rxn_numbers;						
		rxn_numbers_total			= d_xsdata[0].rxn_numbers_total;					
		energy_grid 				= d_xsdata[0].energy_grid;						
		rxn_Q 						= d_xsdata[0].Q;												
		xs 							= d_xsdata[0].xs;												
		//awr 						= d_xsdata[0].awr;										
		//temp 						= d_xsdata[0].temp;										
		//dist_scatter 				= d_xsdata[0].dist_scatter;						
		//dist_energy 				= d_xsdata[0].dist_energy; 
		space						= d_particles[0].space;
		rxn							= d_particles[0].rxn;
		E							= d_particles[0].E;
		Q							= d_particles[0].Q;	
		rn_bank						= d_particles[0].rn_bank;
		cellnum						= d_particles[0].cellnum;
		matnum						= d_particles[0].matnum;
		isonum						= d_particles[0].isonum;
		talnum 						= d_particles[0].talnum;
		//yield						= d_particles[0].yield;
		weight						= d_particles[0].weight;
		index						= d_particles[0].index;
	}

	// make sure shared loads happen before anything else
	__syncthreads();

	// return if terminated
	unsigned this_rxn=rxn[tid_in];
	if (this_rxn>=900){return;}

	//remap
	int tid=d_remap[tid_in];

	// declare
	float		norm[3];
	float		samp_dist		= 0.0;
	float		diff			= 0.0;
	unsigned	this_tope		= 999999999;
	unsigned	array_dex		= 0;
	float		epsilon			= 2.0e-5;
	float		dotp			= 0.0;
	float		macro_t_total	= 0.0;
	//int			flag			= 0;
	float surf_minimum, xhat_new, yhat_new, zhat_new, this_Q;

	// load from arrays
	unsigned	this_mat		=  matnum[tid];
	unsigned	dex				=   index[tid];  
	unsigned	rn				= rn_bank[tid];
	float		this_E			=       E[tid];
	float		x				=   space[tid].x;
	float		y				=   space[tid].y;
	float		z				=   space[tid].z;
	float		xhat			=   space[tid].xhat;
	float		yhat			=   space[tid].yhat;
	float		zhat			=   space[tid].zhat;
	float		surf_dist		=   space[tid].surf_dist;
	unsigned	enforce_BC		=   space[tid].enforce_BC;  
	memcpy(     norm,               space[tid].norm,  3*sizeof(float) );

	//
	//
	//
	//  MACROSCOPIC SECTION
	//  -- find interacting isotope
	//
	//

	// compute some things
	unsigned 	n_columns 		= n_isotopes + total_reaction_channels;
	float 		e0 				= energy_grid[dex];
	float 		e1 				= energy_grid[dex+1];

	if(this_mat>=n_materials){
		printf("MACRO - this_mat %u > n_materials %u!!!!!\n",this_mat,n_materials);
        rxn[tid_in]   = 1001;  
        isonum[tid]   = 0;
		return;
	}

	if (this_rxn>801)printf("multiplicity %u entered macro at E %10.8E\n",this_rxn,this_E);

	// compute the total macroscopic cross section for this material
	macro_t_total = sum_cross_section(	n_isotopes,
										e0, e1, this_E,
										&d_number_density_matrix[this_mat],  
										&xs[ dex   *n_columns],  
										&xs[(dex+1)*n_columns] 				);

	// compute the interaction length
	samp_dist = -logf(get_rand(&rn))/macro_t_total;

	// determine the isotope in the material for this cell
	this_tope = sample_cross_section(	n_isotopes, macro_t_total, get_rand(&rn),
										e0, e1, this_E,
										&d_number_density_matrix[this_mat],  
										&xs[ dex   *n_columns],  
										&xs[(dex+1)*n_columns]					);


	// do surf/samp compare
	diff = surf_dist - samp_dist;

	// calculate epsilon projection onto neutron trajectory
	// dotp positive = neutron is inside the cell (normal points out, trajectory must be coming from inside)
	// dotp negative = neutron is outside the cell
	dotp = 	norm[0]*xhat + 
			norm[1]*yhat + 
			norm[2]*zhat;
	surf_minimum = epsilon / fabsf(dotp);
	
	// surface logic
	if( diff < surf_minimum ){  // need to make some decisions so epsilon is handled correctly
		// if not outer cell, neutron placement is too close to surface.  risk of next interaction not seeing the surface due to epsilon.
		// preserve if in this cell or next, but make sure neutron is at least an epsilon away from the surface.
		if (diff < 0.0){ // next cell, enforce BC or push through
			if (enforce_BC == 1){  // black BC
				x += (surf_dist + 2.1*surf_minimum) * xhat;
				y += (surf_dist + 2.1*surf_minimum) * yhat;
				z += (surf_dist + 2.1*surf_minimum) * zhat;
				this_rxn  = 999;  // leaking is 999
				this_tope=999999997;  
			}
			else if(enforce_BC == 2){  // specular reflection BC
				// move epsilon off of surface
				x += ((surf_dist*xhat) + copysignf(1.0,dotp)*1.2*epsilon*norm[0]); 
				y += ((surf_dist*yhat) + copysignf(1.0,dotp)*1.2*epsilon*norm[1]);
				z += ((surf_dist*zhat) + copysignf(1.0,dotp)*1.2*epsilon*norm[2]);
				// calculate reflection
				xhat_new = -(2.0 * dotp * norm[0]) + xhat; 
				yhat_new = -(2.0 * dotp * norm[1]) + yhat; 
				zhat_new = -(2.0 * dotp * norm[2]) + zhat; 
				// flags
				this_rxn = 801;  // reflection is 801 
				this_tope=999999996;  
			}
			else{   // next cell, move to intersection point, then move *out* epsilon along surface normal
				x += surf_dist*xhat + copysignf(1.0,dotp)*1.2*epsilon*norm[0];
				y += surf_dist*yhat + copysignf(1.0,dotp)*1.2*epsilon*norm[1];
				z += surf_dist*zhat + copysignf(1.0,dotp)*1.2*epsilon*norm[2];
				this_rxn = 800;  // resampling is 800
				this_tope=999999998;  
				}
			}
		else{   // this cell, move to intersection point, then move *in* epsilon along surface normal 
			x += surf_dist*xhat - copysignf(1.0,dotp)*1.2*epsilon*norm[0];
			y += surf_dist*yhat - copysignf(1.0,dotp)*1.2*epsilon*norm[1];
			z += surf_dist*zhat - copysignf(1.0,dotp)*1.2*epsilon*norm[2];
			this_rxn = 0;
		}
	}
	else{  // near side of minimum, can simply move the neutron
			x += samp_dist * xhat;
			y += samp_dist * yhat;
			z += samp_dist * zhat;
			this_rxn = 0;
	}

	//
	//
	//
	//  TALLY SECTION
	//  -- score tally if valid
	//
	//

	// only score tally if not leaked/resampled (collision estimator). 
	if(this_rxn==0){

		unsigned 	my_bin_index 	= 0;

		const float Emax 	= 20.00000;
		const float Emin 	=  1.0e-11;

		// determine bin number
		my_bin_index = logf(my_E/Emin)/logf(Emax/Emin)*(Ntally);

		//score the bins atomicly, could be bad if many neutrons are in a single bin since this will serialize their operations
		atomicAdd(&tally_score [my_bin_index], this_weight/macro_t );
		atomicAdd(&tally_square[my_bin_index], this_weight/(macro_t * macro_t));
		atomicInc(&tally_count [my_bin_index], 4294967295);

	}



	//
	//
	//
	//  MICROSCOPIC SECTION
	//  -- find reaction type
	//
	//

	// only find isotope if not leaked/resampled.
	if(this_rxn==0){

		unsigned	col_start	=	0;
		unsigned	col_end		=	0;
		unsigned	this_col	=	0;
		float		micro_t		=	0.0;

		// compute the index ranges 
		if(this_tope>=n_isotopes){
			printf("micro - ISOTOPE NUMBER FROM MACRO > NUMBER OF ISOTOPES!  n_isotopes %u tope %u\n",n_isotopes,this_tope);
			return;
		}
		else{
			col_start	=	n_isotopes + rxn_numbers_total[this_tope];
			col_end		=	n_isotopes + rxn_numbers_total[this_tope+1];
		}

	
		// compute the interpolated total microscopic cross section for this isotope.  Use non-multiplier function overload.  Remember that total xs is stored in the first n_isotopes of columns, then come the individual reaction cross sections...
		micro_t = sum_cross_section(	1,
										e0, e1, this_E,
										&xs[ dex   *n_columns + this_tope],  
										&xs[(dex+1)*n_columns + this_tope] );
	
		// determine the reaction/Q for this isotope, use non-multiplier function overload.  Returns index from col_start!
		this_col = col_start + sample_cross_section(	(col_end-col_start), micro_t, get_rand(&rn),
														e0, e1, this_E,
														&xs[ dex   *n_columns + col_start],  
														&xs[(dex+1)*n_columns + col_start]	);
		// the the numbers for this column
		this_rxn	=	rxn_numbers[this_col];
		this_Q		=	rxn_Q[      this_col];
		array_dex	=	dex*n_columns + this_col; 
	
		// errors?
		if(this_rxn == 999999999){ // there is a gap in between the last MT and the total cross section, remap the rn to fit into the available data (effectively rescales the total cross section so everything adds up to it, if things aren't samples the first time around)
			printf("micro - REACTION NOT SAMPLED CORRECTLY! tope=%u E=%10.8E dex=%u rxn=%u\n",this_tope, this_E, dex, this_rxn); //most likely becasue rn1=1.0
		}
		if(this_rxn == 3 | this_rxn==4 | this_rxn ==5 | this_rxn ==10 | this_rxn ==27){
			printf("MT=%u!!!, changing to 1102...\n",this_rxn);
			this_rxn = 1102;
		}
	}

	//
	//
	//
	//  OUTPUT
	//  -- write output to arrays
	//
	//

	rxn[    tid_in]			=	this_rxn;			// rxn is sorted WITH the remapping vector, i.e. its index does not need to be remapped
	Q[      tid]			=	this_Q;
	rn_bank[tid]			=	rn;
	index[  tid]			=	this_dex;			// write MT array index to dex instead of energy vector index
	isonum[tid]				=	tope;
	space[  tid].x			=	x;
	space[  tid].y			=	y;
	space[  tid].z			=	z;
	space[  tid].macro_t	=	macro_t_total;
	if( enforce_BC==2 ){
		space[tid].xhat		=	xhat_new;			// write reflected directions for specular BC
		space[tid].yhat		=	yhat_new;
		space[tid].zhat		=	zhat_new;
	}

}

void macro_micro(unsigned NUM_THREADS, unsigned N, unsigned n_materials, unsigned n_tallies, cross_section_data* d_xsdata, particle_data* d_particles, tally_data* d_tally, unsigned* d_remap, float* d_number_density_matrix ){

	unsigned blks = ( N + NUM_THREADS - 1 ) / NUM_THREADS;

	macro_micro_kernel <<< blks, NUM_THREADS >>> ( N, n_materials, n_tallies, d_xsdata, d_particles, d_tally, d_remap, d_number_density_matrix);
	cudaThreadSynchronize();

}

